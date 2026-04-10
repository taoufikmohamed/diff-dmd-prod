"""
DMD-Cloud Webhook Service
Receives GitHub webhooks, deduplicates, and dispatches async AI pipeline generation.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import time
from contextlib import asynccontextmanager
from urllib.parse import urlparse
from typing import Any

import httpx
from fastapi import FastAPI, Request, BackgroundTasks, Header
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

AI_SERVICE_URL = os.getenv("AI_SERVICE_URL", "http://ai-service:8000")
AI_SERVICE_TIMEOUT_SECONDS = float(os.getenv("AI_SERVICE_TIMEOUT_SECONDS", "30"))
WEBHOOK_SECRET = os.getenv("GITHUB_WEBHOOK_SECRET", "")  # HMAC validation
GITHUB_API_URL = os.getenv("GITHUB_API_URL", "https://api.github.com").rstrip("/")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")
AUTO_SAVE_PIPELINE = os.getenv("AUTO_SAVE_PIPELINE", "true").lower() == "true"
PIPELINE_OUTPUT_PATH = os.getenv("PIPELINE_OUTPUT_PATH", ".github/workflows/ci-cd.yml")

# Deduplication: prevent reprocessing the same commit within a TTL window
_seen_commits: dict[str, float] = {}
_DEDUP_TTL_SECONDS = 300  # 5 minutes
_DEDUP_MAX = 1024

_http_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(application: FastAPI):
    global _http_client
    _http_client = httpx.AsyncClient(
        timeout=AI_SERVICE_TIMEOUT_SECONDS,
        limits=httpx.Limits(max_keepalive_connections=5, max_connections=10),
    )
    logger.info("HTTP client pool initialised")
    yield
    await _http_client.aclose()
    logger.info("HTTP client pool closed")


app = FastAPI(title="DMD Webhook Service", version="2.0.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _verify_signature(body: bytes, sig_header: str | None) -> bool:
    """Validate GitHub webhook HMAC-SHA256 signature."""
    if not WEBHOOK_SECRET:
        return True  # secret not configured - skip validation
    if not sig_header or not sig_header.startswith("sha256="):
        return False
    expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    received = sig_header[len("sha256="):]
    return hmac.compare_digest(expected, received)


def _is_duplicate(commit_sha: str) -> bool:
    """Return True if we already processed this commit recently."""
    now = time.monotonic()
    # Prune expired entries
    expired = [k for k, ts in _seen_commits.items() if now - ts > _DEDUP_TTL_SECONDS]
    for k in expired:
        del _seen_commits[k]
    if commit_sha in _seen_commits:
        return True
    if len(_seen_commits) >= _DEDUP_MAX:
        # Evict oldest
        oldest = min(_seen_commits, key=_seen_commits.__getitem__)
        del _seen_commits[oldest]
    _seen_commits[commit_sha] = now
    return False


def _save_pipeline(content: str) -> None:
    if not AUTO_SAVE_PIPELINE or not content.strip():
        return
    from pathlib import Path
    out = Path(PIPELINE_OUTPUT_PATH)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(content.strip() + "\n", encoding="utf-8")
    logger.info("Pipeline saved to %s", out.resolve())


async def _save_pipeline_to_github(payload: dict[str, Any], content: str) -> bool:
    """Create or update generated workflow in the repository that triggered this webhook."""
    if not AUTO_SAVE_PIPELINE or not content.strip():
        return False

    if not GITHUB_TOKEN:
        logger.warning("GITHUB_TOKEN is not configured; cannot save pipeline to repository")
        return False

    repo_name = payload.get("repository", {}).get("full_name", "")
    if not repo_name:
        logger.warning("Cannot save pipeline: missing repository.full_name in payload")
        return False

    ref = payload.get("ref", "")
    branch = ""
    if isinstance(ref, str) and ref.startswith("refs/heads/"):
        branch = ref.split("/", 2)[2]
    if not branch:
        branch = payload.get("repository", {}).get("default_branch", "master")

    path = PIPELINE_OUTPUT_PATH.lstrip("/")
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "dmd-webhook-service",
    }
    contents_url = f"{GITHUB_API_URL}/repos/{repo_name}/contents/{path}"

    try:
        sha = None
        existing = await _http_client.get(contents_url, headers=headers, params={"ref": branch})
        if existing.status_code == 200:
            sha = existing.json().get("sha")
        elif existing.status_code != 404:
            existing.raise_for_status()

        commit_sha = payload.get("after", "")
        short_sha = commit_sha[:7] if commit_sha else "manual"
        body = {
            "message": f"chore(ci): update generated pipeline for {short_sha}",
            "content": base64.b64encode((content.strip() + "\n").encode("utf-8")).decode("ascii"),
            "branch": branch,
        }
        if sha:
            body["sha"] = sha

        upsert = await _http_client.put(contents_url, headers=headers, json=body)
        upsert.raise_for_status()
        logger.info("Pipeline committed to %s on branch %s at %s", repo_name, branch, path)
        return True
    except Exception as exc:
        logger.error("Failed to save pipeline to GitHub for %s: %s", repo_name, exc)
        return False


async def _fetch_github_compare_diff(payload: dict[str, Any]) -> str:
    """Fetch raw git diff from GitHub compare API for push events."""
    repo_name = payload.get("repository", {}).get("full_name", "")
    before = payload.get("before", "")
    after = payload.get("after", "")
    compare_url = payload.get("compare", "")

    if not repo_name or not before or not after:
        logger.warning("Cannot fetch diff: missing repo/before/after in webhook payload")
        return ""

    if compare_url:
        parsed = urlparse(compare_url)
        compare_path = parsed.path
        if compare_path.startswith("/"):
            compare_path = compare_path[1:]
    else:
        compare_path = f"repos/{repo_name}/compare/{before}...{after}"

    headers = {
        "Accept": "application/vnd.github.v3.diff",
        "User-Agent": "dmd-webhook-service",
    }
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"

    compare_url = f"{GITHUB_API_URL}/{compare_path}"
    logger.info("Fetching diff from GitHub compare API for %s", repo_name)
    try:
        response = await _http_client.get(compare_url, headers=headers)
        response.raise_for_status()
        diff_text = response.text.strip()
        if not diff_text:
            logger.warning("GitHub compare API returned empty diff for %s", repo_name)
            return ""
        logger.info("Fetched diff from GitHub (%d chars)", len(diff_text))
        return diff_text
    except Exception as exc:
        logger.error("Failed to fetch diff from GitHub for %s: %s", repo_name, exc)
        return ""


async def _resolve_diff(payload: dict[str, Any]) -> str:
    """Use payload diff when available, otherwise fetch from GitHub compare API."""
    payload_diff = payload.get("diff", "")
    if payload_diff and payload_diff.strip():
        return payload_diff

    return await _fetch_github_compare_diff(payload)


# ---------------------------------------------------------------------------
# Background processor
# ---------------------------------------------------------------------------

async def _process_webhook(payload: dict[str, Any], max_retries: int = 3) -> None:
    diff = await _resolve_diff(payload)
    repo_name = payload.get("repository", {}).get("full_name", "unknown")
    commit_msg = payload.get("head_commit", {}).get("message", "")

    if not diff:
        logger.warning("No diff in payload for %s", repo_name)
        return

    logger.info("Processing diff (%d chars) for %s", len(diff), repo_name)
    ai_request = {"diff": diff, "repository": repo_name, "commit_message": commit_msg}

    for attempt in range(max_retries + 1):
        try:
            response = await _http_client.post(
                f"{AI_SERVICE_URL}/generate-pipeline",
                json=ai_request,
            )
            response.raise_for_status()
            ai_response: dict[str, Any] = response.json()

            if cached := ai_response.get("cached"):
                logger.info("AI service returned cached pipeline (no new API call)")

            choices = ai_response.get("choices", [])
            if choices:
                pipeline_content: str = choices[0].get("message", {}).get("content", "")
                logger.info("Pipeline generated (%d chars)", len(pipeline_content))
                try:
                    saved = await _save_pipeline_to_github(payload, pipeline_content)
                    if not saved:
                        # Keep local write as fallback for local/dev mode.
                        _save_pipeline(pipeline_content)
                except Exception as exc:
                    logger.error("Failed to save pipeline: %s", exc)
            return
        except httpx.TimeoutException as exc:
            logger.error("Timeout (attempt %d): %s", attempt + 1, exc)
        except Exception as exc:
            logger.error("Error (attempt %d): %s: %s", attempt + 1, type(exc).__name__, exc)

        if attempt < max_retries:
            import asyncio
            wait = 2 ** attempt  # 1s, 2s, 4s
            await asyncio.sleep(wait)

    logger.error("Max retries exceeded for %s", repo_name)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.post("/webhook/github")
async def github_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_hub_signature_256: str | None = Header(default=None),
) -> JSONResponse:
    """
    Receive GitHub push webhook.
    Returns 200 immediately; pipeline generation runs in background.
    """
    body = await request.body()

    if not _verify_signature(body, x_hub_signature_256):
        logger.warning("Invalid webhook signature")
        return JSONResponse({"status": "error", "message": "Invalid signature"}, status_code=401)

    try:
        payload: dict[str, Any] = await request.json()
    except Exception:
        return JSONResponse({"status": "error", "message": "Invalid JSON"}, status_code=400)

    repo = payload.get("repository", {}).get("full_name", "unknown")
    commit_sha = payload.get("head_commit", {}).get("id", "")
    commit_msg = payload.get("head_commit", {}).get("message", "")

    logger.info("Webhook received: repo=%s commit=%s", repo, commit_sha[:12] if commit_sha else "?")

    # Deduplication: skip if same commit already queued/processed
    if commit_sha and _is_duplicate(commit_sha):
        logger.info("Duplicate commit %s, skipping", commit_sha[:12])
        return JSONResponse({"status": "skipped", "reason": "duplicate"})

    background_tasks.add_task(_process_webhook, payload)
    return JSONResponse({"status": "received", "message": "Queued for pipeline generation"})


@app.get("/health")
async def health_check() -> dict[str, Any]:
    ai_healthy = False
    try:
        resp = await _http_client.get(f"{AI_SERVICE_URL}/health", timeout=2)
        ai_healthy = resp.status_code == 200
    except Exception as exc:
        logger.warning("AI health check failed: %s", exc)
    return {
        "status": "healthy",
        "version": "2.0.0",
        "ai_service": "healthy" if ai_healthy else "unhealthy",
    }


@app.get("/")
async def root() -> dict[str, str]:
    return {
        "service": "webhook-service",
        "version": "2.0.0",
        "endpoints": "/webhook/github, /health",
    }
