"""
DMD-Cloud AI Service
Generates GitHub Actions CI/CD pipelines from git diffs using DeepSeek AI.
"""
from __future__ import annotations

import hashlib
import logging
import os
import re
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY")
DEEPSEEK_TIMEOUT_SECONDS = float(os.getenv("DEEPSEEK_TIMEOUT_SECONDS", "60"))

# Reuse HTTP connections across requests (reduces TCP overhead & energy use)
_http_client: httpx.AsyncClient | None = None

# In-memory LRU-style cache: avoid calling DeepSeek for identical diffs
_pipeline_cache: dict[str, str] = {}
_CACHE_MAX = 128


@asynccontextmanager
async def lifespan(application: FastAPI):
    """Manage shared resources: open once, reuse, close cleanly."""
    global _http_client
    _http_client = httpx.AsyncClient(
        timeout=DEEPSEEK_TIMEOUT_SECONDS,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    )
    logger.info("HTTP client pool initialised")
    yield
    await _http_client.aclose()
    logger.info("HTTP client pool closed")


app = FastAPI(title="DMD AI Service", version="2.0.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def sanitize_pipeline_yaml(content: str) -> str:
    text = (content or "").strip()
    text = re.sub(r"^```(?:ya?ml)?\s*", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*```$", "", text)

    yaml_start_patterns = (
        "name:", "on:", "jobs:", "permissions:",
        "env:", "defaults:", "concurrency:", "run-name:",
    )
    lines = text.splitlines()
    start_index = None
    for i, line in enumerate(lines):
        if any(line.lstrip().startswith(p) for p in yaml_start_patterns):
            start_index = i
            break

    if start_index is None:
        return text
    return "\n".join(lines[start_index:]).strip()


def fallback_pipeline_yaml() -> str:
    return """name: CI/CD Fallback

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
  workflow_dispatch:

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r ai_service/requirements.txt -r webhook_service/requirements.txt
      - name: Validate syntax
        run: |
          python -m py_compile ai_service/main.py
          python -m py_compile webhook_service/main.py
      - name: Build images
        run: |
          docker build -t ai-service:ci ./ai_service
          docker build -t webhook-service:ci ./webhook_service
          docker build -t orchestrator:ci ./orchestrator
"""


def _diff_hash(diff: str) -> str:
    return hashlib.sha256(diff.encode()).hexdigest()


def _get_cached(diff: str) -> str | None:
    return _pipeline_cache.get(_diff_hash(diff))


def _set_cached(diff: str, pipeline: str) -> None:
    if len(_pipeline_cache) >= _CACHE_MAX:
        _pipeline_cache.pop(next(iter(_pipeline_cache)))
    _pipeline_cache[_diff_hash(diff)] = pipeline


def _fallback_response(reason: str) -> dict[str, Any]:
    return {
        "choices": [{"message": {"content": fallback_pipeline_yaml()}}],
        "fallback": True,
        "reason": reason,
    }


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "version": "2.0.0"}


@app.post("/generate-pipeline")
async def generate_pipeline(data: dict) -> dict[str, Any]:
    if not DEEPSEEK_API_KEY:
        logger.warning("DEEPSEEK_API_KEY missing, using fallback")
        return _fallback_response("DEEPSEEK_API_KEY is not configured")

    diff: str = data.get("diff", "")

    # Cache hit: same diff processed before - saves AI cost and carbon emissions
    if diff and (cached := _get_cached(diff)):
        logger.info("Cache hit for diff %s", _diff_hash(diff)[:12])
        return {"choices": [{"message": {"content": cached}}], "cached": True}

    prompt = (
        "You are a CI/CD pipeline generator.\n\n"
        "Task: Analyze the git diff and produce a GitHub Actions workflow.\n\n"
        "Output rules (strict):\n"
        "- Return ONLY raw YAML.\n"
        "- Do NOT include Markdown fences, explanations or any extra text.\n"
        "- The YAML must be directly saveable as .github/workflows/ci-cd.yml.\n\n"
        f"Git diff:\n{diff}"
    )

    try:
        response = await _http_client.post(
            "https://api.deepseek.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {DEEPSEEK_API_KEY}"},
            json={
                "model": "deepseek-coder",
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.2,
            },
        )
        response.raise_for_status()
    except httpx.TimeoutException:
        logger.warning("DeepSeek timeout")
        return _fallback_response("DeepSeek API request timed out")
    except httpx.HTTPStatusError as exc:
        logger.warning("DeepSeek HTTP %s", exc.response.status_code)
        return _fallback_response(f"DeepSeek API returned {exc.response.status_code}")
    except httpx.RequestError:
        logger.warning("DeepSeek unreachable")
        return _fallback_response("DeepSeek API is unavailable")

    payload: dict[str, Any] = response.json()
    try:
        content: str = payload["choices"][0]["message"].get("content", "")
        cleaned = sanitize_pipeline_yaml(content)
        payload["choices"][0]["message"]["content"] = cleaned
        if diff and cleaned:
            _set_cached(diff, cleaned)
    except (KeyError, IndexError, TypeError):
        logger.warning("Unexpected DeepSeek response format")
        return _fallback_response("DeepSeek API returned an unexpected response format")

    return payload
