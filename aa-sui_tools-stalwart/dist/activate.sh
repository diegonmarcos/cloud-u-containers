#!/bin/sh
set -e
URL="https://localhost:2443/api/principal"
PW=$(cat /opt/containers/stalwart/.secrets.d/ADMIN_PASSWORD 2>/dev/null)
[ -z "$PW" ] && echo "[activate] No ADMIN_PASSWORD found, skipping" && exit 0

echo "[activate] Waiting for Stalwart to start..."
for i in $(seq 1 30); do
  curl -sk -u "admin:$PW" "$URL" -o /dev/null 2>/dev/null && break
  sleep 2
done

echo "[activate] Ensuring domain + accounts..."
curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"type":"domain","name":"diegonmarcos.com"}' 2>/dev/null || true

curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"type":"individual","name":"me@diegonmarcos.com","secrets":["'"$PW"'"],"emails":["me@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null || true

NR_PW=$(cat /opt/containers/stalwart/.secrets.d/NOREPLY_PASSWORD 2>/dev/null || echo "noreply")
curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"type":"individual","name":"no-reply@diegonmarcos.com","secrets":["'"$NR_PW"'"],"emails":["no-reply@diegonmarcos.com","noreply@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null || true

echo "[activate] Done — accounts ensured"
