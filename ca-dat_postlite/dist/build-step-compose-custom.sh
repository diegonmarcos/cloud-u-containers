#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Custom compose: pure docker CLI (no compose Go binary)
# Project: dist | Services: 8
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
echo "  pull: germanorizzo/ws4sqlite:v0.16.6" && docker pull germanorizzo/ws4sqlite:v0.16.6 2>/dev/null &
echo "  pull: ghcr.io/diegonmarcos/postlite:latest" && docker pull ghcr.io/diegonmarcos/postlite:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- postlite-authelia ---
docker rm -f postlite-authelia 2>/dev/null || true
docker run -d --name postlite-authelia --label com.docker.compose.project=postlite-authelia --label com.docker.compose.service=postlite-authelia --network host -v /home/diego/authelia/config:/data ghcr.io/diegonmarcos/postlite:latest -addr :5436 -data-dir /data
echo "  started: postlite-authelia"
# --- postlite-npm ---
docker rm -f postlite-npm 2>/dev/null || true
docker run -d --name postlite-npm --label com.docker.compose.project=postlite-npm --label com.docker.compose.service=postlite-npm --network host -v /home/diego/npm/data:/data ghcr.io/diegonmarcos/postlite:latest -addr :5433 -data-dir /data
echo "  started: postlite-npm"
# --- postlite-ntfy ---
docker rm -f postlite-ntfy 2>/dev/null || true
docker run -d --name postlite-ntfy --label com.docker.compose.project=postlite-ntfy --label com.docker.compose.service=postlite-ntfy --network host -v /home/diego/ntfy/cache:/data ghcr.io/diegonmarcos/postlite:latest -addr :5435 -data-dir /data
echo "  started: postlite-ntfy"
# --- postlite-vaultwarden ---
docker rm -f postlite-vaultwarden 2>/dev/null || true
docker run -d --name postlite-vaultwarden --label com.docker.compose.project=postlite-vaultwarden --label com.docker.compose.service=postlite-vaultwarden --network host -v /home/diego/vaultwarden/data:/data ghcr.io/diegonmarcos/postlite:latest -addr :5434 -data-dir /data
echo "  started: postlite-vaultwarden"
# --- sqlite-authelia ---
docker rm -f sqlite-authelia 2>/dev/null || true
docker run -d --name sqlite-authelia --label com.docker.compose.project=sqlite-authelia --label com.docker.compose.service=sqlite-authelia --network host -v /home/diego/authelia/config:/data germanorizzo/ws4sqlite:v0.16.6 -port 8893 -db /data/db.sqlite3?mode=ro
echo "  started: sqlite-authelia"
# --- sqlite-npm ---
docker rm -f sqlite-npm 2>/dev/null || true
docker run -d --name sqlite-npm --label com.docker.compose.project=sqlite-npm --label com.docker.compose.service=sqlite-npm --network host -v /home/diego/npm/data:/data germanorizzo/ws4sqlite:v0.16.6 -port 8890 -db /data/database.sqlite?mode=ro
echo "  started: sqlite-npm"
# --- sqlite-ntfy ---
docker rm -f sqlite-ntfy 2>/dev/null || true
docker run -d --name sqlite-ntfy --label com.docker.compose.project=sqlite-ntfy --label com.docker.compose.service=sqlite-ntfy --network host -v /home/diego/ntfy/cache:/data germanorizzo/ws4sqlite:v0.16.6 -port 8892 -db /data/cache.db?mode=ro
echo "  started: sqlite-ntfy"
# --- sqlite-vaultwarden ---
docker rm -f sqlite-vaultwarden 2>/dev/null || true
docker run -d --name sqlite-vaultwarden --label com.docker.compose.project=sqlite-vaultwarden --label com.docker.compose.service=sqlite-vaultwarden --network host -v /home/diego/vaultwarden/data:/data germanorizzo/ws4sqlite:v0.16.6 -port 8891 -db /data/db.sqlite3?mode=ro
echo "  started: sqlite-vaultwarden"
