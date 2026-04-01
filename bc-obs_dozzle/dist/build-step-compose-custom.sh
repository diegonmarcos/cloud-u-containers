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
echo "  pull: ghcr.io/diegonmarcos/dozzle:latest" && docker pull ghcr.io/diegonmarcos/dozzle:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- dozzle ---
docker rm -f dozzle 2>/dev/null || true
docker run -d --name dozzle --label com.docker.compose.project=dozzle --label com.docker.compose.service=dozzle --network host --dns 10.0.0.1 --dns 1.1.1.1 -v /var/run/docker.sock:/var/run/docker.sock:ro --ulimit nofile=65536:65536 -e "DOZZLE_ADDR=:9999" -e "DOZZLE_LEVEL=info" --memory 67108864 --cpus 1 --memory-reservation 67108864 --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/dozzle:latest
echo "  started: dozzle"
