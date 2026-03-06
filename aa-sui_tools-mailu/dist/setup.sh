#!/bin/sh
set -e
cd "$(dirname "$0")"

# Load secrets so NOREPLY_PASSWORD is available
if [ -f .secrets ]; then
  while IFS='=' read -r _key _val; do
    case "$_key" in ""|\#*) continue ;; esac
    export "$_key=$_val"
  done < .secrets
fi

echo "[setup] Waiting for admin container..."
sleep 5

# Ensure no-reply@ user exists (used by Authelia for sending notifications)
echo "[setup] Creating no-reply@ user..."
docker exec mailu-admin-1 flask mailu user no-reply diegonmarcos.com "$NOREPLY_PASSWORD" 2>/dev/null || echo "[setup] no-reply@ already exists"

# Remove stale admin@ account if it exists
echo "[setup] Removing stale admin@ account..."
docker exec mailu-admin-1 flask mailu user-delete admin diegonmarcos.com 2>/dev/null || echo "[setup] admin@ not found, skipping"

echo "[setup] Done. Active accounts: me@ (superadmin), no-reply@ (SMTP sender)"
