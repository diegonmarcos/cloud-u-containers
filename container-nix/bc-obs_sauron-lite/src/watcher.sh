#!/bin/bash
# Sauron-Lite: Watcher component
# Detects file changes and queues them for YARA scanning
set -euo pipefail

WATCH_DIRS="${WATCH_DIRS:-/watch/etc /watch/home}"
QUEUE_FILE="${QUEUE_FILE:-/var/spool/sauron/scan-queue.txt}"
LOG_FILE="${LOG_FILE:-/var/log/sauron/changes.log}"
VM_NAME="${VM_NAME:-unknown}"
EXCLUDE_PATTERN="${EXCLUDE_PATTERN:-.log$|.tmp$|.swp$|.cache|__pycache__|node_modules|.git}"

# Scannable extensions (potential malware carriers)
SCAN_EXTENSIONS="sh|bash|py|pl|rb|php|js|exe|bin|so|dll|ps1|bat|cmd|vbs"

mkdir -p "$(dirname "$QUEUE_FILE")" "$(dirname "$LOG_FILE")"
touch "$QUEUE_FILE"

log_change() {
    local event="$1"
    local path="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "[$timestamp] $event: $path" >> "$LOG_FILE"

    # Queue file for YARA scan if it's a scannable type
    if [[ "$path" =~ \.($SCAN_EXTENSIONS)$ ]] && [[ -f "$path" ]]; then
        echo "$path" >> "$QUEUE_FILE"
    fi
}

echo "[$(date -Iseconds)] Sauron Watcher starting..."
echo "[$(date -Iseconds)] Watching: $WATCH_DIRS"

inotifywait -m -r \
    --exclude "$EXCLUDE_PATTERN" \
    -e create -e modify -e moved_to \
    --format '%e|%w%f' \
    $WATCH_DIRS 2>/dev/null | while IFS='|' read -r events filepath; do

    case "$filepath" in
        *.log|*.tmp|*.swp|*~) continue ;;
    esac

    log_change "$events" "$filepath"
done
