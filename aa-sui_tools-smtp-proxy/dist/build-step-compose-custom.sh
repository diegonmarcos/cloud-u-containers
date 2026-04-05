#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Custom compose: pure docker CLI (no compose Go binary)
# Project: dist | Services: 1
set -e

# Ensure Docker daemon is running
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  if ! docker info >/dev/null 2>&1; then
    echo "[compose-custom] ERROR: Docker failed to start" >&2
    exit 1
  fi
fi

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/smtp-proxy:latest" && docker pull ghcr.io/diegonmarcos/smtp-proxy:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- smtp-proxy ---
docker rm -f smtp-proxy 2>/dev/null || true
docker run -d --name smtp-proxy --label com.docker.compose.project=smtp-proxy --label com.docker.compose.service=smtp-proxy --network host --env-file .secrets -e "LISTEN_PORT=8080" -e "SMTP_HOST=localhost" -e "SMTP_PORT=25" ghcr.io/diegonmarcos/smtp-proxy:latest
echo "  started: smtp-proxy"
