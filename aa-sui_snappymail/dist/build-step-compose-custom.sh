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
docker volume create snappymail_data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/snappymail:latest" && docker pull ghcr.io/diegonmarcos/snappymail:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- snappymail ---
docker rm -f snappymail 2>/dev/null || true
docker run -d --name snappymail --label com.docker.compose.project=snappymail --label com.docker.compose.service=snappymail --network host --dns 10.0.0.1 --dns 1.1.1.1 -v snappymail_data:/var/lib/snappymail -v ./config/application.ini:/opt/snappymail-config/application.ini:ro -v ./config/domains:/var/lib/snappymail/_data_/_default_/domains --ulimit nofile=65536:65536 --memory 67108864 --cpus 1 --memory-reservation 16777216 --health-cmd "curl -sf http://localhost:8888/" --health-interval 30s --health-timeout 10s --health-retries 3 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" --entrypoint "/bin/sh" ghcr.io/diegonmarcos/snappymail:latest -c "cp -f /opt/snappymail-config/application.ini /var/lib/snappymail/_data_/_default_/configs/application.ini 2>/dev/null || true; exec /entrypoint.sh"
echo "  started: snappymail"
