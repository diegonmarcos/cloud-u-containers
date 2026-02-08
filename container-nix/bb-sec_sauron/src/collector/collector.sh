#!/bin/bash
# Collector: Watches journald + Sauron, POSTs to Alerts API
set -e

API_URL="${API_URL:-https://alerts.diegonmarcos.com}"
NTFY_URL="${NTFY_URL:-https://rss.diegonmarcos.com}"
VM_NAME="${VM_NAME:-unknown}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

# ntfy topics
TOPIC_SYSTEM="system"
TOPIC_AUTH="auth"
TOPIC_SAURON="sauron"

log() {
    echo "[$(date -Iseconds)] $1"
}

# Send alert to API (which forwards to ntfy)
send_alert() {
    local topic="$1"
    local title="$2"
    local message="$3"
    local priority="${4:-default}"
    local tags="${5:-}"
    local service="${6:-system}"
    local log_cmd="${7:-}"

    # Try API first
    local response
    response=$(curl -s -X POST "$API_URL/api/alerts" \
        -H "Content-Type: application/json" \
        -d "{
            \"vm\": \"$VM_NAME\",
            \"service\": \"$service\",
            \"topic\": \"$topic\",
            \"title\": \"$title\",
            \"message\": \"$message\",
            \"priority\": \"$priority\",
            \"tags\": \"$tags\",
            \"log_cmd\": \"$log_cmd\"
        }" 2>/dev/null) || true

    # Fallback to direct ntfy if API fails
    if [ -z "$response" ] || echo "$response" | grep -q "error"; then
        curl -s -X POST "$NTFY_URL/$topic" \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: $tags" \
            -d "$message" > /dev/null 2>&1 || true
    fi
}

# Send heartbeat to API
send_heartbeat() {
    curl -s -X POST "$API_URL/api/vms/$VM_NAME/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"status\": \"online\"}" > /dev/null 2>&1 || true
}

# Parse journald for SSH events
check_ssh() {
    # Failed SSH attempts in last interval
    local failed
    failed=$(journalctl -u sshd --since "-${CHECK_INTERVAL}s" --no-pager 2>/dev/null | grep -c "Failed password" 2>/dev/null) || failed=0
    if [ "$failed" -gt 0 ] 2>/dev/null; then
        send_alert "$TOPIC_AUTH" \
            "SSH: $failed failed logins" \
            "[$VM_NAME] $failed failed SSH login attempts" \
            "high" \
            "warning,lock" \
            "ssh" \
            "journalctl -u sshd --since '${CHECK_INTERVAL}s ago' --no-pager"
    fi

    # Successful SSH logins
    local success
    success=$(journalctl -u sshd --since "-${CHECK_INTERVAL}s" --no-pager 2>/dev/null | grep -c "Accepted" 2>/dev/null) || success=0
    if [ "$success" -gt 0 ] 2>/dev/null; then
        send_alert "$TOPIC_AUTH" \
            "SSH: $success logins" \
            "[$VM_NAME] $success successful SSH logins" \
            "default" \
            "key,unlock" \
            "ssh" \
            "journalctl -u sshd --since '${CHECK_INTERVAL}s ago' --no-pager | grep Accepted"
    fi
}

# Parse journald for Docker events
check_docker() {
    # Container crashes/restarts
    local crashes
    crashes=$(journalctl -u docker --since "-${CHECK_INTERVAL}s" --no-pager 2>/dev/null | grep -cE "died|killed|OOM" 2>/dev/null) || crashes=0
    if [ "$crashes" -gt 0 ] 2>/dev/null; then
        send_alert "$TOPIC_SYSTEM" \
            "Docker: container crash" \
            "[$VM_NAME] $crashes container crash events" \
            "high" \
            "whale,warning" \
            "docker" \
            "journalctl -u docker --since '${CHECK_INTERVAL}s ago' --no-pager | grep -E 'died|killed|OOM'"
    fi
}

# Parse journald for system errors
check_system() {
    # Critical/emergency messages (use -o cat to avoid "-- No entries --" header)
    local msg
    msg=$(journalctl -p 0..2 --since "-${CHECK_INTERVAL}s" --no-pager -o cat 2>/dev/null | head -1)
    if [ -n "$msg" ]; then
        send_alert "$TOPIC_SYSTEM" \
            "Critical: $VM_NAME" \
            "$msg" \
            "urgent" \
            "rotating_light" \
            "system" \
            "journalctl -p 0..2 --since '${CHECK_INTERVAL}s ago' --no-pager"
    fi
}

# Check Sauron logs for detections
check_sauron() {
    # Read sauron container logs
    local alerts
    alerts=$(docker logs sauron --since "${CHECK_INTERVAL}s" 2>&1 | grep -c "ALERT" 2>/dev/null) || alerts=0
    if [ "$alerts" -gt 0 ] 2>/dev/null; then
        local details
        details=$(docker logs sauron --since "${CHECK_INTERVAL}s" 2>&1 | grep "detected" | tail -1)
        send_alert "$TOPIC_SAURON" \
            "Malware detected: $VM_NAME" \
            "$details" \
            "urgent" \
            "biohazard,skull" \
            "sauron" \
            "docker logs sauron --since '${CHECK_INTERVAL}s'"
    fi
}

# Main loop
log "Collector starting..."
log "API: $API_URL"
log "NTFY: $NTFY_URL (fallback)"
log "VM: $VM_NAME"
log "Interval: ${CHECK_INTERVAL}s"

# Send startup notification
send_alert "$TOPIC_SYSTEM" \
    "Collector started" \
    "[$VM_NAME] Log collector is now active" \
    "low" \
    "rocket" \
    "collector" \
    ""

while true; do
    send_heartbeat
    check_ssh
    check_docker
    check_system
    check_sauron
    sleep "$CHECK_INTERVAL"
done
