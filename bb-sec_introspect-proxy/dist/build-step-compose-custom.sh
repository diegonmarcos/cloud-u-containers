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
echo "  pull: ghcr.io/diegonmarcos/introspect-proxy:latest" && docker pull ghcr.io/diegonmarcos/introspect-proxy:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- introspect-proxy ---
docker rm -f introspect-proxy 2>/dev/null || true
docker run -d --name introspect-proxy --label com.docker.compose.project=introspect-proxy --label com.docker.compose.service=introspect-proxy --network host --dns 10.0.0.1 --dns 1.1.1.1 --ulimit nofile=65536:65536 --env-file .secrets --health-cmd "curl -sf http://localhost:4182/health" --health-interval 30s --health-timeout 10s --health-retries 3 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/introspect-proxy:latest
echo "  started: introspect-proxy"
