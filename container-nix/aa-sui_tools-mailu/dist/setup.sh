#!/bin/sh
set -e
echo "[setup] Waiting for admin container..."
sleep 5

echo "[setup] Creating no-reply alias..."
docker exec mailu-admin-1 flask mailu alias no-reply diegonmarcos.com me@diegonmarcos.com 2>/dev/null || echo "[setup] Alias already exists"

echo "[setup] Done."
