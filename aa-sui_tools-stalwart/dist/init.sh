#!/bin/sh
set -e

ENV_VARS='$ADMIN_PASSWORD $ME_PASSWORD $NOREPLY_PASSWORD $DKIM_PRIVATE_KEY_B64'

echo "[init] Substituting secrets into config.toml..."
envsubst "$ENV_VARS" < /opt/stalwart-mail/etc/config.toml.tpl > /opt/stalwart-mail/etc/config.toml

# Decode DKIM private key from base64
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM private key..."
  mkdir -p /opt/stalwart-mail/dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /opt/stalwart-mail/dkim/diegonmarcos.com.dkim.key
  chmod 600 /opt/stalwart-mail/dkim/diegonmarcos.com.dkim.key
fi

# Auto-create domain + user principals in internal directory (RocksDB may be wiped)
# Background task: wait for Stalwart to start, then ensure all principals exist
(sleep 10 && AUTH="admin@diegonmarcos.com:$ADMIN_PASSWORD" && \
  curl -sk -X POST "https://localhost:2443/api/principal" \
    -u "$AUTH" -H "Content-Type: application/json" \
    -d '{"type":"domain","name":"diegonmarcos.com"}' 2>/dev/null && \
  curl -sk -X POST "https://localhost:2443/api/principal" \
    -u "$AUTH" -H "Content-Type: application/json" \
    -d '{"type":"individual","name":"me@diegonmarcos.com","secrets":["'"$ME_PASSWORD"'"],"emails":["me@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null && \
  curl -sk -X POST "https://localhost:2443/api/principal" \
    -u "$AUTH" -H "Content-Type: application/json" \
    -d '{"type":"individual","name":"no-reply@diegonmarcos.com","secrets":["'"$NOREPLY_PASSWORD"'"],"emails":["no-reply@diegonmarcos.com","noreply@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null && \
  echo "[init] All principals ensured in internal directory" || true) &

echo "[init] Starting Stalwart..."
exec /usr/local/bin/stalwart-mail --config /opt/stalwart-mail/etc/config.toml
