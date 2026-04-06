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

# Create volumes
docker volume create alerts-data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/alerts-api:latest" && docker pull ghcr.io/diegonmarcos/alerts-api:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- alerts-api ---
docker rm -f alerts-api 2>/dev/null || true
docker run -d --name alerts-api --label com.docker.compose.project=alerts-api --label com.docker.compose.service=alerts-api --network host --read-only --tmpfs /tmp --dns 10.0.0.1 --dns 1.1.1.1 -v alerts-data:/data --ulimit nofile=65536:65536 -e "DB_PATH=/data/alerts.db" -e "LOG_LEVEL=info" -e "NTFY_URL=https://rss.diegonmarcos.com" --memory 67108864 --cpus 0.1 --memory-reservation 67108864 --health-cmd "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:5000/api/health')\"" --health-interval 30s --health-timeout 10s --health-retries 3 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/alerts-api:latest
echo "  started: alerts-api"
