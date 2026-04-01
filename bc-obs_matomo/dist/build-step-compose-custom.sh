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
docker volume create matomo_inbox 2>/dev/null || true
docker volume create matomo_matomo_data 2>/dev/null || true
docker volume create matomo_matomo_db 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/matomo-hybrid:latest" && docker pull ghcr.io/diegonmarcos/matomo-hybrid:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- matomo-hybrid ---
docker rm -f matomo-hybrid 2>/dev/null || true
docker run -d --name matomo-hybrid --label com.docker.compose.project=matomo-hybrid --label com.docker.compose.service=matomo-hybrid --network host -v matomo_matomo_data:/var/www/html -v matomo_matomo_db:/var/lib/mysql -v matomo_inbox:/inbox -e "MATOMO_API_TOKEN=" -e "MATOMO_DATABASE_DBNAME=matomo" -e "MATOMO_DATABASE_HOST=localhost" -e "MATOMO_DATABASE_PASSWORD=<REDACTED-LEAK-2026-04-21>" -e "MATOMO_DATABASE_USERNAME=matomo" --memory 1073741824 --memory-reservation 67108864 ghcr.io/diegonmarcos/matomo-hybrid:latest
echo "  started: matomo-hybrid"
