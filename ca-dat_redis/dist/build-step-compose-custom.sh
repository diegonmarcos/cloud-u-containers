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
echo "  pull: ghcr.io/diegonmarcos/redis:latest" && docker pull ghcr.io/diegonmarcos/redis:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- redis ---
docker rm -f redis 2>/dev/null || true
docker run -d --name redis --label com.docker.compose.project=redis --label com.docker.compose.service=redis --network host -v /data/redis:/data -e "REDIS_PASSWORD=authelia-redis-password-change-me" --env-file .secrets --health-cmd "redis-cli ping" --health-interval 30s --health-timeout 10s --health-retries 3 ghcr.io/diegonmarcos/redis:latest sh -c "redis-server --appendonly yes --maxmemory 128mb --maxmemory-policy allkeys-lru --requirepass "$$REDIS_PASSWORD""
echo "  started: redis"
