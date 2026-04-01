#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Run this instead of 'docker compose up' on E2 Micro VMs (1GB RAM)
# Project: dist | Services: 2
set -e

# Create volumes
docker volume create authelia_data 2>/dev/null || true
docker volume create authelia_redis_data 2>/dev/null || true

# Pull latest images
echo "  pull: ghcr.io/diegonmarcos/authelia:latest"
docker pull ghcr.io/diegonmarcos/authelia:latest 2>/dev/null || true
echo "  pull: ghcr.io/diegonmarcos/redis:latest"
docker pull ghcr.io/diegonmarcos/redis:latest 2>/dev/null || true

# --- authelia ---
docker rm -f authelia 2>/dev/null || true
docker run -d --name authelia --label com.docker.compose.project=authelia --label com.docker.compose.service=authelia --network host --dns 10.0.0.1 --dns 1.1.1.1 -v authelia_data:/data -v ./config/oidc_jwks.pem:/config/oidc_jwks.pem:ro --ulimit nofile=65536:65536 -e "TZ=Europe/Madrid" --env-file .secrets --memory 134217728 --cpus 1 --memory-reservation 33554432 --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" --entrypoint "sh" ghcr.io/diegonmarcos/authelia:latest /config/init.sh
echo "  started: authelia"
# --- redis ---
docker rm -f authelia-redis 2>/dev/null || true
docker run -d --name authelia-redis --label com.docker.compose.project=redis --label com.docker.compose.service=redis --network host --dns 10.0.0.1 --dns 1.1.1.1 -v authelia_redis_data:/data --ulimit nofile=65536:65536 --env-file .secrets --memory 50331648 --cpus 1 --memory-reservation 16777216 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/redis:latest sh -c "redis-server --port 6380 --requirepass $$AUTHELIA_REDIS_PASSWORD --appendonly yes --appendfsync everysec --save 900 1 --save 300 10"
echo "  started: authelia-redis"
