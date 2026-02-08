#!/bin/bash
# Sauron-Lite entrypoint: runs watcher + cron for scanner
set -e

echo "[$(date -Iseconds)] Sauron-Lite starting..."
echo "[$(date -Iseconds)] Mode: Watcher (realtime) + Scanner (every 5min)"

# Start crond in background for periodic YARA scans
crond -b -l 8

# Run initial scan of watched directories
echo "[$(date -Iseconds)] Running initial scan..."
/usr/local/bin/scanner.sh || true

# Start watcher in foreground
exec /usr/local/bin/watcher.sh
