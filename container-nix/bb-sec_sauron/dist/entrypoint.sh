#!/bin/bash
set -e

RULES_DIR="${RULES_DIR:-/etc/sauron/yara-rules}"
WATCH_DIR="${WATCH_DIR:-/watch}"
LOG_FILE="${LOG_FILE:-/var/log/sauron/sauron.log}"
SCAN_INTERVAL="${SCAN_INTERVAL:-300}"
LAST_SCAN_MARKER="/tmp/.last_scan"
SCAN_OUTPUT="/tmp/scan_results.json"

echo "[$(date -Iseconds)] Sauron starting..." | tee -a "$LOG_FILE"
echo "[$(date -Iseconds)] Watching: $WATCH_DIR" | tee -a "$LOG_FILE"
echo "[$(date -Iseconds)] Rules: $RULES_DIR" | tee -a "$LOG_FILE"
echo "[$(date -Iseconds)] Mode: Incremental (only new/modified files)" | tee -a "$LOG_FILE"

cd "$WATCH_DIR"

scan_files() {
    local files="$1"
    local count=$(echo "$files" | grep -c "^" 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ] || [ -z "$files" ]; then
        echo "[$(date -Iseconds)] No files to scan"
        return
    fi

    echo "[$(date -Iseconds)] Scanning $count file(s)..."

    # Create temp file list
    echo "$files" > /tmp/scan_list.txt

    # Scan each file individually
    rm -f "$SCAN_OUTPUT"
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        /usr/local/bin/sauron \
            --rules "$RULES_DIR" \
            --root "$file" \
            --scan \
            --workers "${WORKERS:-1}" \
            --report-json \
            --report-output /tmp/single_scan.json \
            --report-errors 2>/dev/null || true

        # Append if detection found
        if [ -f /tmp/single_scan.json ]; then
            if grep -q '"detected":true' /tmp/single_scan.json 2>/dev/null; then
                cat /tmp/single_scan.json >> "$SCAN_OUTPUT"
            fi
            rm -f /tmp/single_scan.json
        fi
    done < /tmp/scan_list.txt

    # Report detections
    if [ -f "$SCAN_OUTPUT" ]; then
        local detections
        detections=$(grep -c '"detected":true' "$SCAN_OUTPUT" 2>/dev/null) || detections=0
        if [ "$detections" -gt 0 ]; then
            echo "[$(date -Iseconds)] ALERT: $detections threats detected!"
            cat "$SCAN_OUTPUT"
        fi
        rm -f "$SCAN_OUTPUT"
    else
        echo "[$(date -Iseconds)] Scan complete. No threats found."
    fi
}

# First run: full scan
echo "[$(date -Iseconds)] Initial full scan..."
touch "$LAST_SCAN_MARKER"
FILES=$(find "$WATCH_DIR" -type f 2>/dev/null)
scan_files "$FILES"

# Main loop: incremental scans
while true; do
    echo "[$(date -Iseconds)] Next scan in ${SCAN_INTERVAL}s..."
    sleep "$SCAN_INTERVAL"

    # Find only files modified since last scan
    echo "[$(date -Iseconds)] Checking for new/modified files..."
    FILES=$(find "$WATCH_DIR" -type f -newer "$LAST_SCAN_MARKER" 2>/dev/null)
    touch "$LAST_SCAN_MARKER"

    scan_files "$FILES"
done
