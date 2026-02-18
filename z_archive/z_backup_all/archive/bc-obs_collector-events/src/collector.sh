#!/bin/sh
# Lightweight Shell Collector
set -e

VM_NAME="${VM_NAME:-unknown}"
NTFY_URL="${NTFY_URL:-http://ntfy:80}"

send_alert() {
    topic="$1"
    title="$2"
    msg="$3"
    priority="${4:-default}"
    
    curl -sf -m 3 "$NTFY_URL/$topic"         -H "Title: $title"         -H "Priority: $priority"         -H "Tags: $topic"         -d "$msg" >/dev/null 2>&1 || true
}

# Auth: SSH logins
journalctl -o cat -n 5 --since '5m ago' _COMM=sshd 2>/dev/null | grep -i 'accepted\|failed' | head -3 | while read line; do
    sev="default"
    echo "$line" | grep -qi failed && sev="high"
    send_alert "auth" "[$VM_NAME] SSH" "$line" "$sev"
done

# Docker: Container events
docker events --since '5m' --until 'now' --format '{{.Action}} {{.Actor.Attributes.name}}' 2>/dev/null | grep -E 'die|kill|oom|stop' | head -5 | while read line; do
    sev="high"
    echo "$line" | grep -q oom && sev="urgent"
    send_alert "docker" "[$VM_NAME] Container" "$line" "$sev"
done

# System: Critical errors
journalctl -o cat -p 3 -n 3 --since '5m ago' 2>/dev/null | head -3 | while read line; do
    send_alert "system" "[$VM_NAME] Error" "$line" "high"
done

# Disk: >90% usage
disk=$(df -h / | awk 'NR==2 {gsub(/%/,"",$5); if($5>90) print $5"%"}')
[ -n "$disk" ] && send_alert "system" "[$VM_NAME] Disk Critical" "Root disk at $disk" "urgent"

echo "OK"
