#!/bin/bash
# Import buffered tracking payloads from /inbox/ into Matomo via Bulk Tracking API
set -e

INBOX_DIR="/inbox"
MATOMO_URL="http://127.0.0.1:8081/matomo.php"
TOKEN="${MATOMO_API_TOKEN:-}"
BATCH_SIZE=50

# Check if there are files to import
mapfile -t FILE_LIST < <(find "$INBOX_DIR" -name '*.json' -type f 2>/dev/null | sort)
TOTAL=${#FILE_LIST[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "[import] No payloads to import"
    exit 0
fi

echo "[import] Found $TOTAL payloads to import"

# Verify Matomo is responding
if ! curl -sf "$MATOMO_URL" >/dev/null 2>&1; then
    echo "[import] ERROR: Matomo is not responding at $MATOMO_URL"
    echo "[import] Run matomo-wake.sh first"
    exit 1
fi

# Check for API token
if [ -z "$TOKEN" ]; then
    echo "[import] WARNING: MATOMO_API_TOKEN not set — Matomo IGNORES both cip and cdt"
    echo "[import]   · cip: every visit is attributed to the server IP, so location_country"
    echo "[import]     is 'xx' for the whole batch."
    echo "[import]   · cdt: any hit older than 24h is stamped with the IMPORT time instead of"
    echo "[import]     when it was captured. A backlog therefore collapses into one hour and"
    echo "[import]     every by-time report of it is wrong. THIS IS SILENT — the requests"
    echo "[import]     succeed, the counts look right, only the timestamps are fiction."
    echo "[import]   Provision MATOMO_API_TOKEN (sops) before importing a backlog you intend"
    echo "[import]   to trust for anything time-based."
fi

IMPORTED=0
FAILED=0
BATCH_REQUESTS=""
BATCH_FILES=()
BATCH_COUNT=0

send_batch() {
    if [ "$BATCH_COUNT" -eq 0 ]; then
        return
    fi

    # Build JSON payload for bulk tracking API
    local json_payload
    if [ -n "$TOKEN" ]; then
        json_payload="{\"requests\":[${BATCH_REQUESTS}],\"token_auth\":\"${TOKEN}\"}"
    else
        json_payload="{\"requests\":[${BATCH_REQUESTS}]}"
    fi

    # Send bulk request
    local response
    response=$(curl -sf -X POST "$MATOMO_URL" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>&1) || {
        echo "[import] ERROR: Batch request failed"
        FAILED=$((FAILED + BATCH_COUNT))
        BATCH_REQUESTS=""
        BATCH_FILES=()
        BATCH_COUNT=0
        return
    }

    # Check response for success
    if echo "$response" | grep -q '"status":"success"'; then
        for f in "${BATCH_FILES[@]}"; do
            rm -f "$f"
        done
        IMPORTED=$((IMPORTED + BATCH_COUNT))
        echo "[import] Batch imported: $BATCH_COUNT payloads"
    else
        echo "[import] WARNING: Batch response: $response"
        FAILED=$((FAILED + BATCH_COUNT))
    fi

    BATCH_REQUESTS=""
    BATCH_FILES=()
    BATCH_COUNT=0
}

for filepath in "${FILE_LIST[@]}"; do
    [ -z "$filepath" ] && continue

    # Parse JSON payload
    # A GET hit carries its params in .query; a POST hit carries them in
    # .post_body (receive.php records the raw body verbatim). Reading only
    # .query silently dropped EVERY POST — which is exactly what the Android
    # analytics module sends, so no app event could ever reach Matomo even
    # with the collector healthy. Prefer .query, fall back to .post_body.
    query=$(jq -r '.query // ""' "$filepath" 2>/dev/null) || query=""
    if [ -z "$query" ]; then
        query=$(jq -r '.post_body // ""' "$filepath" 2>/dev/null) || query=""
    fi
    ip=$(jq -r '.ip // ""' "$filepath" 2>/dev/null) || ip=""
    timestamp=$(jq -r '.timestamp // ""' "$filepath" 2>/dev/null) || timestamp=""

    if [ -z "$query" ]; then
        echo "[import] SKIP: Empty query in $filepath"
        rm -f "$filepath"
        continue
    fi

    # Build the tracking request query string
    request_qs="$query"

    # Add client IP override (requires token_auth)
    if [ -n "$ip" ] && [ -n "$TOKEN" ]; then
        encoded_ip=$(jq -rn --arg v "$ip" '$v|@uri')
        request_qs="${request_qs}&cip=${encoded_ip}"
    fi

    # Add custom datetime (requires token_auth)
    if [ -n "$timestamp" ] && [ -n "$TOKEN" ]; then
        encoded_ts=$(jq -rn --arg v "$timestamp" '$v|@uri')
        request_qs="${request_qs}&cdt=${encoded_ts}"
    fi

    # Append to batch
    if [ -n "$BATCH_REQUESTS" ]; then
        BATCH_REQUESTS="${BATCH_REQUESTS},\"?${request_qs}\""
    else
        BATCH_REQUESTS="\"?${request_qs}\""
    fi
    BATCH_FILES+=("$filepath")
    BATCH_COUNT=$((BATCH_COUNT + 1))

    # Send batch when it reaches BATCH_SIZE
    if [ "$BATCH_COUNT" -ge "$BATCH_SIZE" ]; then
        send_batch
    fi
done

# Send remaining batch
send_batch

echo "[import] Complete: imported=$IMPORTED, failed=$FAILED, total=$TOTAL"
