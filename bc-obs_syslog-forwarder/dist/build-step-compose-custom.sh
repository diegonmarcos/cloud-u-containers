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
docker volume create syslog-cache 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/syslog-forwarder:latest" && docker pull ghcr.io/diegonmarcos/syslog-forwarder:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- syslog-forwarder ---
docker rm -f syslog-forwarder 2>/dev/null || true
docker run -d --name syslog-forwarder --label com.docker.compose.project=syslog-forwarder --label com.docker.compose.service=syslog-forwarder --network host -v /opt/sauron/config/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro -v sauron-logs:/var/log/sauron:ro -v syslog-cache:/var/cache/syslog-ng -e "CENTRAL_HOST=" -e "CENTRAL_PORT=5514" -e "VM_NAME=unknown" ghcr.io/diegonmarcos/syslog-forwarder:latest
echo "  started: syslog-forwarder"
