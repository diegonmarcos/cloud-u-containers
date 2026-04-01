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
docker volume create fluent-bit-db 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/fluent-bit:latest" && docker pull ghcr.io/diegonmarcos/fluent-bit:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- fluent-bit ---
docker rm -f fluent-bit 2>/dev/null || true
docker run -d --name fluent-bit --label com.docker.compose.project=fluent-bit --label com.docker.compose.service=fluent-bit --network host -v /opt/fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro -v /opt/fluent-bit/parsers.conf:/fluent-bit/etc/parsers.conf:ro -v /var/lib/docker/containers:/var/lib/docker/containers:ro -v /var/log:/var/log:ro -v fluent-bit-db:/fluent-bit/db ghcr.io/diegonmarcos/fluent-bit:latest
echo "  started: fluent-bit"
