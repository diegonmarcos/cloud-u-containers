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
docker volume create umami_config 2>/dev/null || true
docker volume create umami_db_data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/umami-db:latest" && docker pull ghcr.io/diegonmarcos/umami-db:latest 2>/dev/null &
echo "  pull: ghcr.io/diegonmarcos/umami:latest" && docker pull ghcr.io/diegonmarcos/umami:latest 2>/dev/null &
echo "  pull: ghcr.io/diegonmarcos/umami-setup:latest" && docker pull ghcr.io/diegonmarcos/umami-setup:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- umami ---
docker rm -f umami 2>/dev/null || true
docker run -d --name umami --label com.docker.compose.project=umami --label com.docker.compose.service=umami --network host -e "ADMIN_PASSWORD=ogeid2B@" -e "ADMIN_USERNAME=me@diegonmarcos.com" -e "APP_SECRET=" -e "BASE_PATH=/umami" -e "DATABASE_TYPE=postgresql" -e "DATABASE_URL=postgresql://umami:@localhost:5442/umami" -e "DB_PASSWORD=T5kD9oUeEthRr6adqmIsolOm08BDGWU" -e "DISABLE_TELEMETRY=1" -e "PORT=3006" --env-file .secrets --memory 134217728 --memory-reservation 33554432 --health-cmd "curl -sf http://localhost:3006/api/heartbeat || exit 1" --health-interval 15s --health-timeout 5s --health-retries 5 ghcr.io/diegonmarcos/umami:latest
echo "  started: umami"
# --- umami-db ---
docker rm -f umami-db 2>/dev/null || true
docker run -d --name umami-db --label com.docker.compose.project=umami-db --label com.docker.compose.service=umami-db --network host -v umami_db_data:/var/lib/postgresql/data -e "PGPORT=5442" -e "POSTGRES_DB=umami" -e "POSTGRES_PASSWORD=" -e "POSTGRES_USER=umami" --memory 134217728 --memory-reservation 33554432 --health-cmd "pg_isready -U umami -p 5442" --health-interval 10s --health-timeout 5s --health-retries 5 ghcr.io/diegonmarcos/umami-db:latest -p 5442
echo "  started: umami-db"
# --- umami-setup ---
docker rm -f umami-setup 2>/dev/null || true
docker run -d --name umami-setup --label com.docker.compose.project=umami-setup --label com.docker.compose.service=umami-setup --network host -v umami_config:/output -e "ADMIN_PASSWORD=ogeid2B@" -e "ADMIN_USERNAME=me@diegonmarcos.com" -e "APP_SECRET=HIbbRuNrfwipt1DZfl3Rs5efSYF1iTH" -e "DB_PASSWORD=T5kD9oUeEthRr6adqmIsolOm08BDGWU" --env-file .secrets --entrypoint "/bin/sh" ghcr.io/diegonmarcos/umami-setup:latest /setup/setup.sh
echo "  started: umami-setup"
