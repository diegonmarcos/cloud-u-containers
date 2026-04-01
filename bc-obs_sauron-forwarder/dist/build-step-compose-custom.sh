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
echo "  pull: ghcr.io/diegonmarcos/sauron-forwarder:latest" && docker pull ghcr.io/diegonmarcos/sauron-forwarder:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- sauron-forwarder ---
docker rm -f sauron-forwarder 2>/dev/null || true
docker run -d --name sauron-forwarder --label com.docker.compose.project=sauron-forwarder --label com.docker.compose.service=sauron-forwarder --network host -v sauron-data:/var/log/sauron:ro -e "CENTRAL_HOST=" -e "CENTRAL_PORT=5514" --entrypoint "/bin/sh" ghcr.io/diegonmarcos/sauron-forwarder:latest -c
echo "  started: sauron-forwarder"
