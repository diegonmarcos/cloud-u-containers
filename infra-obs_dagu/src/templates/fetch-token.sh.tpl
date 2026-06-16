#!/bin/sh

# Fetch OIDC token via client_credentials grant, export as AUTHELIA_BEARER_TOKEN
# so all existing DAG workflows keep working without changes.
# Starts dagu regardless — token failure is non-fatal (DAGs using bearer will fail individually).
echo "[fetch-token] Requesting OIDC token from $AUTHELIA_TOKEN_URL ..."
RESPONSE=$(curl -s --max-time 10 -X POST "$AUTHELIA_TOKEN_URL" \
  -u "$AUTHELIA_OIDC_CLIENT_ID:$AUTHELIA_OIDC_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=authelia.bearer.authz" 2>&1) || true

TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN" ]; then
  export AUTHELIA_BEARER_TOKEN="$TOKEN"
  echo "[fetch-token] Token acquired (${#TOKEN} chars)"
else
  echo "[fetch-token] WARNING: Failed to get OIDC token — dagu will start without bearer auth"
  echo "[fetch-token] Response: $RESPONSE"
fi

# Start ntfy→dagu WebSocket bridge in background
ntfy-bridge.sh &

exec dagu start-all
