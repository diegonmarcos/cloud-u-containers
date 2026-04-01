#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Custom compose: pure docker CLI (no compose Go binary)
# Project: dist | Services: 3
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
docker volume create ntfy_cache 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/ntfy-github-rss:latest" && docker pull ghcr.io/diegonmarcos/ntfy-github-rss:latest 2>/dev/null &
echo "  pull: ghcr.io/diegonmarcos/ntfy:latest" && docker pull ghcr.io/diegonmarcos/ntfy:latest 2>/dev/null &
echo "  pull: ghcr.io/diegonmarcos/ntfy-syslog-bridge:latest" && docker pull ghcr.io/diegonmarcos/ntfy-syslog-bridge:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- github-rss ---
docker rm -f github-rss 2>/dev/null || true
docker run -d --name github-rss --label com.docker.compose.project=github-rss --label com.docker.compose.service=github-rss --network host --dns 10.0.0.1 --dns 1.1.1.1 -v ntfy_cache:/var/cache/ntfy --ulimit nofile=65536:65536 -e "PYTHONUNBUFFERED=1" -e "TZ=Europe/Paris" --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/ntfy-github-rss:latest python -u /app/github-rss-to-ntfy.py
echo "  started: github-rss"
# --- ntfy ---
docker rm -f ntfy 2>/dev/null || true
docker run -d --name ntfy --label com.docker.compose.project=ntfy --label com.docker.compose.service=ntfy --network host --dns 10.0.0.1 --dns 1.1.1.1 -v ntfy_cache:/var/cache/ntfy --ulimit nofile=65536:65536 -e "NTFY_ADMIN_PASSWORD=ntfy-admin-2026" -e "NTFY_USER_PASSWORD=ogeid2B@" -e "TZ=Europe/Paris" --env-file .secrets --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" --entrypoint "/init-ntfy.sh" ghcr.io/diegonmarcos/ntfy:latest
echo "  started: ntfy"
# --- syslog-bridge ---
docker rm -f syslog-bridge 2>/dev/null || true
docker run -d --name syslog-bridge --label com.docker.compose.project=syslog-bridge --label com.docker.compose.service=syslog-bridge --network host --dns 10.0.0.1 --dns 1.1.1.1 -v ntfy_cache:/var/cache/ntfy -v /var/log:/var/log:ro --ulimit nofile=65536:65536 -e "PYTHONUNBUFFERED=1" -e "TZ=Europe/Paris" --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/ntfy-syslog-bridge:latest python -u /app/syslog-to-ntfy.py
echo "  started: syslog-bridge"
