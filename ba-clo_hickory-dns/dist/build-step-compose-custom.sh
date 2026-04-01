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
echo "  pull: ghcr.io/diegonmarcos/hickory-dns:latest" && docker pull ghcr.io/diegonmarcos/hickory-dns:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- hickory-dns ---
docker rm -f hickory-dns 2>/dev/null || true
docker run -d --name hickory-dns --label com.docker.compose.project=hickory-dns --label com.docker.compose.service=hickory-dns --network host --read-only --tmpfs /tmp --dns 1.1.1.1 --dns 8.8.8.8 -v ./config/named.toml:/etc/named.toml:ro -v ./config/zones:/etc/zones:ro --ulimit nofile=65536:65536 -e "RUST_LOG=hickory_dns=info,hickory_server=info" --memory 50331648 --cpus 1 --memory-reservation 16777216 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/hickory-dns:latest
echo "  started: hickory-dns"
