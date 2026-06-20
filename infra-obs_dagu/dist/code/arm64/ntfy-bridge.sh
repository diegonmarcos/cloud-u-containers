#!/bin/sh
# ntfy → Dagu WebSocket bridge
# Subscribes to ntfy topics via WebSocket, triggers Dagu DAGs on messages.
# Config: /etc/dagu/triggers.json — maps ntfy topics to DAG names.
set -u

NTFY_URL="${NTFY_WS_URL:-ws://10.0.0.6:8090}"
DAGU_API="${DAGU_API_URL:-http://localhost:${DAGU_PORT:-8070}}"
TRIGGERS="${TRIGGERS_FILE:-/etc/dagu/triggers.json}"

# Build comma-separated topic list from triggers.json keys
TOPICS=$(jq -r 'keys | join(",")' "$TRIGGERS")
if [ -z "$TOPICS" ]; then
  echo "[ntfy-bridge] No topics in $TRIGGERS — exiting"
  exit 0
fi

echo "[ntfy-bridge] Subscribing to: $TOPICS"
echo "[ntfy-bridge] Dagu API: $DAGU_API"

# Reconnect loop — websocat exits on connection drop
while true; do
  websocat -t --ping-interval 30 --ping-timeout 60 "${NTFY_URL}/${TOPICS}/ws" 2>/dev/null | \
  while IFS= read -r line; do
    # Skip non-message events (open, keepalive)
    event=$(echo "$line" | jq -r '.event // empty' 2>/dev/null)
    [ "$event" != "message" ] && continue

    topic=$(echo "$line" | jq -r '.topic' 2>/dev/null)
    [ -z "$topic" ] && continue

    # Look up DAGs to trigger for this topic
    dags=$(jq -r --arg t "$topic" '.[$t] // [] | .[]' "$TRIGGERS" 2>/dev/null)
    for dag in $dags; do
      echo "[ntfy-bridge] $(date -u +%H:%M:%S) trigger: $dag (topic: $topic)"
      curl -sf -X POST "${DAGU_API}/api/v1/dags/${dag}/start" \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null 2>&1 || \
        echo "[ntfy-bridge] WARN: failed to trigger $dag"
    done
  done

  echo "[ntfy-bridge] Connection lost — reconnecting in 5s"
  sleep 5
done
