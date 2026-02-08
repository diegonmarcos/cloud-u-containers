#!/bin/bash
# Sauron-Lite: Scanner component
# Runs periodically to YARA scan queued files
set -euo pipefail

# Run with low priority (nice 19 = lowest priority)
renice 19 $$ >/dev/null 2>&1 || true

QUEUE_FILE="${QUEUE_FILE:-/var/spool/sauron/scan-queue.txt}"
ALERTS_FILE="${ALERTS_FILE:-/var/log/sauron/alerts.jsonl}"
RULES_DIR="${RULES_DIR:-/etc/sauron/yara-rules}"
VM_NAME="${VM_NAME:-unknown}"
MAX_FILE_SIZE="${MAX_FILE_SIZE:-5242880}"  # 5MB

mkdir -p "$(dirname "$ALERTS_FILE")"

log_alert() {
    local severity="$1"
    local rule="$2"
    local path="$3"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    printf '{"timestamp":"%s","vm":"%s","severity":"%s","rule":"%s","path":"%s"}\n' \
        "$timestamp" "$VM_NAME" "$severity" "$rule" "$path" | tee -a "$ALERTS_FILE"
}

# Check if queue exists and has content
if [[ ! -s "$QUEUE_FILE" ]]; then
    echo "[$(date -Iseconds)] No files in queue"
    exit 0
fi

# Get unique files from queue
SCAN_LIST=$(mktemp)
sort -u "$QUEUE_FILE" > "$SCAN_LIST"
> "$QUEUE_FILE"  # Clear queue

FILE_COUNT=$(wc -l < "$SCAN_LIST")
echo "[$(date -Iseconds)] Scanning $FILE_COUNT files..."

# Scan each file
while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    [[ ! -f "$filepath" ]] && continue

    # Skip large files
    filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    if (( filesize > MAX_FILE_SIZE )); then
        echo "Skipping large file: $filepath ($filesize bytes)"
        continue
    fi

    # Run YARA scan
    if result=$(yara -r "$RULES_DIR" "$filepath" 2>/dev/null); then
        if [[ -n "$result" ]]; then
            # Parse YARA output: "rulename filepath"
            rule=$(echo "$result" | awk '{print $1}')
            log_alert "high" "$rule" "$filepath"
        fi
    fi

    # Small delay between files to prevent CPU spike
    sleep 0.1
done < "$SCAN_LIST"

rm -f "$SCAN_LIST"
echo "[$(date -Iseconds)] Scan complete"
