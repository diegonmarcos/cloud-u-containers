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
docker volume create vaultwarden_data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/vaultwarden:latest" && docker pull ghcr.io/diegonmarcos/vaultwarden:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- vaultwarden ---
docker rm -f vaultwarden 2>/dev/null || true
docker run -d --name vaultwarden --label com.docker.compose.project=vaultwarden --label com.docker.compose.service=vaultwarden --network host --read-only --tmpfs /tmp --dns 10.0.0.1 --dns 1.1.1.1 -v vaultwarden_data:/data --ulimit nofile=65536:65536 -e "ADMIN_TOKEN=" -e "DOMAIN=https://vault.diegonmarcos.com" -e "INVITATIONS_ALLOWED=true" -e "LOG_LEVEL=warn" -e "ROCKET_PORT=8880" -e "SHOW_PASSWORD_HINT=false" -e "SIGNUPS_ALLOWED=true" -e "SMTP_FROM=noreply@diegonmarcos.com" -e "SMTP_HOST=10.0.0.3" -e "SMTP_PASSWORD=" -e "SMTP_PORT=465" -e "SMTP_SECURITY=force_tls" -e "SMTP_USERNAME=noreply@diegonmarcos.com" -e "WEBSOCKET_ENABLED=true" --env-file .secrets --memory 134217728 --cpus 1 --memory-reservation 33554432 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/vaultwarden:latest
echo "  started: vaultwarden"
