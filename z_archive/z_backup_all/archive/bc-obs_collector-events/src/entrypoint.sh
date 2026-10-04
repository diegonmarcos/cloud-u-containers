#!/bin/sh
set -e
INTERVAL="${INTERVAL:-300}"
TIMEOUT="${TIMEOUT:-10}"
echo "[$(date -Iseconds)] Collector starting (interval: ${INTERVAL}s)"
while true; do
    echo "[$(date -Iseconds)] Running collection..."
    timeout "$TIMEOUT" /usr/local/bin/collector || echo "[$(date -Iseconds)] Collection done"
    echo "[$(date -Iseconds)] Sleeping ${INTERVAL}s..."
    sleep "$INTERVAL"
done
