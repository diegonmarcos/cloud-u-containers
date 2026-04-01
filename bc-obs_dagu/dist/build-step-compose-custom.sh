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
docker volume create dagu_data 2>/dev/null || true

# Pull images in parallel
echo "  pull: ghcr.io/diegonmarcos/dagu:latest" && docker pull ghcr.io/diegonmarcos/dagu:latest 2>/dev/null &
wait
echo "  all pulls done"

# --- dagu ---
docker rm -f dagu 2>/dev/null || true
docker run -d --name dagu --label com.docker.compose.project=dagu --label com.docker.compose.service=dagu --network host --dns 10.0.0.1 --dns 1.1.1.1 -v dagu_data:/var/lib/dagu/data -v /opt/ssh-keys/dagu:/root/.ssh:ro --ulimit nofile=65536:65536 -e "AUTHELIA_OIDC_CLIENT_ID=dagu-cc" -e "AUTHELIA_OIDC_CLIENT_SECRET=" -e "AUTHELIA_OIDC_DAGU_SECRET=14d31d000fbd710a19f3b40c97c3a7b0b948f728280e29b41e3901c0edb607eb" -e "AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token" -e "BORG_PASSPHRASE=B/GG7ockbhuPHuex29eIBoUb9iIy1iH+buVr8+S3eos=" -e "DAGU_AUTH_BASIC_PASSWORD=" -e "DAGU_AUTH_BASIC_USERNAME=" -e "DAGU_AUTH_MODE=basic" -e "DAGU_BASE_CONFIG=/var/lib/dagu/base.yaml" -e "DAGU_DAGS_DIR=/var/lib/dagu/dags" -e "DAGU_HOST=0.0.0.0" -e "DAGU_PASSWORD=mLF9qF/T91nWS3gQXYQlwsQDfvWH0k+C" -e "DAGU_PORT=8070" -e "DAGU_TZ=Europe/Berlin" -e "DAGU_UI_LOGO_TITLE=C3 Workflows" -e "DAGU_UI_NAVBAR_COLOR=#1a1a2e" -e "DAGU_USERNAME=dagu" -e "OCI_S3_SECRET_KEY=B/GG7ockbhuPHuex29eIBoUb9iIy1iH+buVr8+S3eos=" -e "RESTIC_PASSWORD=EML61UfIMe8dtoYeLemdqIEAIjvxfOjW" --env-file .secrets --memory 268435456 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" --entrypoint "dagu" ghcr.io/diegonmarcos/dagu:latest start-all
echo "  started: dagu"
