# ---- Backend image: FastAPI served by uvicorn ----
FROM python:3.12-slim

# No .pyc files, unbuffered logs (so `docker logs` / `kubectl logs` show output immediately)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# CI passes the git SHA here so /api/version reports exactly which build is
# running - handy for confirming a deploy or a rollback.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

WORKDIR /app

# Install dependencies first so this layer is cached when only code changes.
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app ./app

# Run as an unprivileged user (Kubernetes manifests also enforce runAsNonRoot).
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 8000

# Docker-level health check (Kubernetes uses its own probes instead).
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
