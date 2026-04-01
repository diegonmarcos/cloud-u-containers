#!/bin/sh
set -e
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  docker info >/dev/null 2>&1 || { echo "[compose-custom] ERROR: Docker failed to start" >&2; exit 1; }
fi
ENV_FILE_FLAG=""
[ -f .secrets ] && ENV_FILE_FLAG="--env-file .secrets"
docker compose $ENV_FILE_FLAG up -d --force-recreate
