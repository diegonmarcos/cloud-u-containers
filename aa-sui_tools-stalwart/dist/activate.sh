#!/bin/sh
set -e
BASE="https://localhost:2443"
URL="$BASE/api/principal"
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
  -d '{"type":"individual","name":"me@diegonmarcos.com","secrets":["'"$PW"'"],"emails":["me@diegonmarcos.com"],"roles":["admin"]}' 2>/dev/null || true

NR_PW=$(cat /opt/containers/stalwart/.secrets.d/NOREPLY_PASSWORD 2>/dev/null || echo "noreply")
curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"type":"individual","name":"no-reply@diegonmarcos.com","secrets":["'"$NR_PW"'"],"emails":["no-reply@diegonmarcos.com","noreply@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null || true

# ── Upload Sieve script via JMAP ────────────────────────────────
SIEVE_FILE="/opt/containers/stalwart/default.sieve"
USER="me@diegonmarcos.com"
JMAP_URL="$BASE/jmap/"

if [ ! -f "$SIEVE_FILE" ]; then
  echo "[activate] No default.sieve found, skipping sieve upload"
  echo "[activate] Done — accounts ensured"
  exit 0
fi

echo "[activate] Uploading Sieve script for $USER..."

# Step 0: Discover JMAP accountId from session (Stalwart uses short IDs, not emails)
SESSION=$(curl -sk -L -u "$USER:$PW" "$BASE/jmap/session" 2>/dev/null)
ACCOUNT_ID=$(printf '%s' "$SESSION" | grep -o '"urn:ietf:params:jmap:sieve":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$ACCOUNT_ID" ]; then
  echo "[activate] WARNING: Could not discover JMAP accountId"
  echo "[activate] Done — accounts ensured (sieve skipped)"
  exit 0
fi
echo "[activate] JMAP accountId: $ACCOUNT_ID"

# Step 1: Upload .sieve as blob
UPLOAD_RESP=$(curl -sk -u "$USER:$PW" \
  -X POST "$BASE/jmap/upload/$ACCOUNT_ID/" \
  -H "Content-Type: application/sieve" \
  --data-binary @"$SIEVE_FILE" 2>/dev/null)

BLOB_ID=$(printf '%s' "$UPLOAD_RESP" | grep -o '"blobId":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$BLOB_ID" ]; then
  echo "[activate] WARNING: Sieve blob upload failed: $UPLOAD_RESP"
  echo "[activate] Done — accounts ensured (sieve skipped)"
  exit 0
fi
echo "[activate] Blob uploaded: $BLOB_ID"

# Step 2: Create + activate SieveScript via JMAP
JMAP_RESP=$(curl -sk -u "$USER:$PW" \
  -X POST "$JMAP_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve"],
    "methodCalls": [
      ["SieveScript/set", {
        "accountId": "'"$ACCOUNT_ID"'",
        "create": {
          "inbox-rules": {
            "name": "inbox-rules",
            "blobId": "'"$BLOB_ID"'"
          }
        },
        "onSuccessActivateScript": "#inbox-rules"
      }, "0"]
    ]
  }' 2>/dev/null)

if printf '%s' "$JMAP_RESP" | grep -q '"created"'; then
  echo "[activate] Sieve script created and activated for $USER"
else
  # Script may already exist — update it
  echo "[activate] Script exists, attempting update..."
  LIST_RESP=$(curl -sk -u "$USER:$PW" \
    -X POST "$JMAP_URL" \
    -H "Content-Type: application/json" \
    -d '{
      "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve"],
      "methodCalls": [
        ["SieveScript/get", {
          "accountId": "'"$ACCOUNT_ID"'"
        }, "0"]
      ]
    }' 2>/dev/null)

  SCRIPT_ID=$(printf '%s' "$LIST_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$SCRIPT_ID" ]; then
    curl -sk -u "$USER:$PW" \
      -X POST "$JMAP_URL" \
      -H "Content-Type: application/json" \
      -d '{
        "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:sieve"],
        "methodCalls": [
          ["SieveScript/set", {
            "accountId": "'"$ACCOUNT_ID"'",
            "update": {
              "'"$SCRIPT_ID"'": {
                "blobId": "'"$BLOB_ID"'"
              }
            },
            "onSuccessActivateScript": "'"$SCRIPT_ID"'"
          }, "0"]
        ]
      }' 2>/dev/null
    echo "[activate] Sieve script updated and activated"
  else
    echo "[activate] WARNING: Could not find existing script to update"
  fi
fi

echo "[activate] Done — accounts + sieve ensured"
