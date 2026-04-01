#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Run this instead of 'docker compose up' on E2 Micro VMs (1GB RAM)
# Project: dist | Services: 1
set -e

# Pull latest images
echo "  pull: ghcr.io/diegonmarcos/hickory-dns:latest"
docker pull ghcr.io/diegonmarcos/hickory-dns:latest 2>/dev/null || true

# --- hickory-dns ---
docker rm -f hickory-dns 2>/dev/null || true
docker run -d --name hickory-dns --label com.docker.compose.project=hickory-dns --label com.docker.compose.service=hickory-dns --network host --read-only --tmpfs /tmp --dns 1.1.1.1 --dns 8.8.8.8 -v ./config/named.toml:/etc/named.toml:ro -v ./config/zones:/etc/zones:ro --ulimit nofile=65536:65536 -e "RUST_LOG=hickory_dns=info,hickory_server=info" --memory 50331648 --cpus 1 --memory-reservation 16777216 --security-opt no-new-privileges:true --log-driver json-file --log-opt max-file="3" --log-opt max-size="10m" ghcr.io/diegonmarcos/hickory-dns:latest
echo "  started: hickory-dns"
