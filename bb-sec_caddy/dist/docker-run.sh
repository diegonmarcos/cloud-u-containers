#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Run this instead of 'docker compose up' on E2 Micro VMs (1GB RAM)
# Project: dist | Services: 2
set -e

# Create volumes
docker volume create caddy_config 2>/dev/null || true
docker volume create caddy_data 2>/dev/null || true
docker volume create caddy_logs 2>/dev/null || true

# Pull latest images
echo "  pull: ghcr.io/diegonmarcos/caddy:latest"
docker pull ghcr.io/diegonmarcos/caddy:latest 2>/dev/null || true
echo "  pull: ghcr.io/diegonmarcos/introspect-proxy:latest"
docker pull ghcr.io/diegonmarcos/introspect-proxy:latest 2>/dev/null || true

# --- caddy ---
docker rm -f caddy 2>/dev/null || true
docker run -d --name caddy --label com.docker.compose.project=caddy --label com.docker.compose.service=caddy --network host --dns 10.0.0.1 --dns 1.1.1.1 -v caddy_logs:/var/log/caddy -v caddy_data:/data -v caddy_config:/config --ulimit nofile=65536:65536 --env-file .secrets --memory 134217728 --cpus 1 --memory-reservation 50331648 --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/caddy:latest
echo "  started: caddy"
# --- introspect-proxy ---
docker rm -f introspect-proxy 2>/dev/null || true
docker run -d --name introspect-proxy --label com.docker.compose.project=introspect-proxy --label com.docker.compose.service=introspect-proxy --network host --read-only --tmpfs /tmp --dns 10.0.0.1 --dns 1.1.1.1 --ulimit nofile=65536:65536 -e "DEBUG=true" -e "ISSUER=https://auth.diegonmarcos.com" -e "JWKS_URL=https://auth.diegonmarcos.com/jwks.json" -e "REQUIRED_SCOPE=authelia.bearer.authz" --memory 67108864 --cpus 1 --memory-reservation 16777216 --health-cmd "python3 -c import urllib.request; urllib.request.urlopen('http://localhost:4182/health')" --health-interval 30s --health-timeout 5s --health-retries 3 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/introspect-proxy:latest
echo "  started: introspect-proxy"
