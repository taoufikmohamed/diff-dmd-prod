# syntax=docker/dockerfile:1
# ---- builder ----
FROM python:3.11-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- final ----
FROM python:3.11-slim
LABEL org.opencontainers.image.source="https://github.com/taoufikmohamed/diff-dmd"
LABEL org.opencontainers.image.description="DMD webhook receiver service"

RUN useradd --no-create-home --uid 1000 appuser
WORKDIR /app

COPY --from=builder /install /usr/local
COPY main.py .

USER appuser
EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001", \
     "--workers", "1", "--loop", "uvloop", "--log-level", "info"]
