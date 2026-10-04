#!/bin/bash
# Periodic Matomo archiving + daily auto-update
# Runs as a supervisor program while Matomo is awake
set -e

ARCHIVE_INTERVAL=1800   # 30 minutes
UPDATE_INTERVAL=86400   # 24 hours
LAST_UPDATE=0

echo "[archiver] Starting periodic archiver (every ${ARCHIVE_INTERVAL}s)"

while true; do
    sleep "$ARCHIVE_INTERVAL"

    # ─── Archive reports ──────────────────────────────────────────────────
    echo "[archiver] Running core:archive..."
    php -d memory_limit=512M \
        /var/www/html/console core:archive \
        --force-all-websites 2>&1 || {
        echo "[archiver] WARNING: Archiving had errors (non-fatal)"
    }

    # ─── Auto-update (once per day) ──────────────────────────────────────
    NOW=$(date +%s)
    if [ $((NOW - LAST_UPDATE)) -ge "$UPDATE_INTERVAL" ]; then
        echo "[archiver] Checking for Matomo updates..."
        php -d memory_limit=512M \
            /var/www/html/console core:update --yes 2>&1 || {
            echo "[archiver] WARNING: Update check had errors (non-fatal)"
        }
        LAST_UPDATE=$NOW
    fi
done
