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
docker volume create stalwart_data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/stalwart:latest" && docker pull ghcr.io/diegonmarcos/stalwart:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- stalwart ---
docker rm -f stalwart 2>/dev/null || true
docker run -d --name stalwart --label com.docker.compose.project=stalwart --label com.docker.compose.service=stalwart --network host --dns 10.0.0.1 --dns 1.1.1.1 -v stalwart_data:/opt/stalwart-mail/data --ulimit nofile=65536:65536 -e "TZ=Europe/Madrid" --env-file .secrets --memory 536870912 --cpus 1 --memory-reservation 67108864 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" --entrypoint "sh" ghcr.io/diegonmarcos/stalwart:latest /opt/stalwart-mail/init.sh
echo "  started: stalwart"
