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

# Auto-create domain + user principals in internal directory
# Background task: wait for Stalwart to start, then ensure all principals exist
# Uses POST to create (idempotent — fieldAlreadyExists is fine)
# Then PATCH to set passwords (avoids shell quoting issues with POST secrets)
(sleep 10 && AUTH="admin@diegonmarcos.com:$ADMIN_PASSWORD" && \
  URL="https://localhost:2443/api/principal" && \
  curl -sk -X POST "$URL" -u "$AUTH" -H "Content-Type: application/json" \
    -d '{"type":"domain","name":"diegonmarcos.com"}' 2>/dev/null && \
  curl -sk -X POST "$URL" -u "$AUTH" -H "Content-Type: application/json" \
    -d '{"type":"individual","name":"me@diegonmarcos.com","emails":["me@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null && \
  curl -sk -X POST "$URL" -u "$AUTH" -H "Content-Type: application/json" \
    -d '{"type":"individual","name":"no-reply@diegonmarcos.com","emails":["no-reply@diegonmarcos.com","noreply@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null && \
  curl -sk -X PATCH "$URL/me@diegonmarcos.com" -u "$AUTH" -H "Content-Type: application/json" \
    -d "[{\"action\":\"addItem\",\"field\":\"secrets\",\"value\":\"$ME_PASSWORD\"}]" 2>/dev/null && \
  curl -sk -X PATCH "$URL/no-reply@diegonmarcos.com" -u "$AUTH" -H "Content-Type: application/json" \
    -d "[{\"action\":\"addItem\",\"field\":\"secrets\",\"value\":\"$NOREPLY_PASSWORD\"}]" 2>/dev/null && \
  echo "[init] All principals ensured in internal directory" || true) &

echo "[init] Starting Stalwart..."
exec /usr/local/bin/stalwart --config /opt/stalwart-mail/etc/config.toml
