#!/bin/bash
#
# Malware Scan Reports
# Collects Sauron YARA scanner reports from all VMs
#

# VM Configuration
declare -A VMS=(
    ["oci-micro-1"]="130.110.251.193"   # Mail
    ["oci-micro-2"]="129.151.228.66"    # Matomo
    ["gcp-micro-1"]="35.226.147.64"     # Proxy
    ["oci-flex-1"]="84.235.234.87"      # Photos
)

SSH_KEY_OCI="${SSH_KEY_OCI:-/root/.ssh/id_rsa}"
SSH_KEY_GCP="${SSH_KEY_GCP:-/root/.ssh/google_compute_engine}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

get_ssh_key() {
    local vm_name="$1"
    if [[ "$vm_name" == gcp-* ]]; then
        echo "$SSH_KEY_GCP"
    else
        echo "$SSH_KEY_OCI"
    fi
}

cat << EOF

## Malware Scan Reports (Sauron)

EOF

# Function to collect sauron data from a VM
collect_sauron_report() {
    local vm_name="$1"
    local vm_ip="$2"
    local ssh_user="${3:-ubuntu}"

    echo "### $vm_name ($vm_ip)"
    echo ""

    # Check if VM is reachable
    if ! timeout 5 nc -z "$vm_ip" 22 2>/dev/null; then
        echo "**Status:** [WARN] VM unreachable (SSH port closed)"
        echo ""
        return 1
    fi

    # Try to get Sauron status via SSH
    local ssh_key
    ssh_key=$(get_ssh_key "$vm_name")
    local sauron_data
    sauron_data=$(ssh $SSH_OPTS -i "$ssh_key" "$ssh_user@$vm_ip" '
        # Check if sauron is running
        if docker ps --filter "name=sauron" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
            echo "STATUS:running"

            # Get memory/cpu
            mem=$(docker stats --no-stream sauron --format "{{.MemUsage}}" 2>/dev/null)
            cpu=$(docker stats --no-stream sauron --format "{{.CPUPerc}}" 2>/dev/null)
            echo "MEM:$mem"
            echo "CPU:$cpu"

            # Count alerts with detections
            alerts=$(docker exec sauron cat /var/log/sauron/alerts.jsonl 2>/dev/null | grep -c "detected.*true" || echo "0")
            echo "ALERTS:$alerts"

            # Get last 5 detections
            echo "DETECTIONS_START"
            docker exec sauron cat /var/log/sauron/alerts.jsonl 2>/dev/null | \
                grep "detected.*true" | tail -5 | \
                jq -r '"| \(.scanned_at) | \(.path) | \(.tags | join(\", \")) |"' 2>/dev/null
            echo "DETECTIONS_END"

            # Last scan time
            last_log=$(docker logs --tail 1 sauron 2>&1)
            echo "LASTLOG:$last_log"
        else
            # Check if sauron exists but stopped
            if docker ps -a --filter "name=sauron" --format "{{.Status}}" 2>/dev/null | head -1 | grep -q .; then
                echo "STATUS:stopped"
            else
                echo "STATUS:not_installed"
            fi
        fi
    ' 2>/dev/null)

    if [[ -z "$sauron_data" ]]; then
        echo "**Status:** [WARN] Could not connect via SSH"
        echo ""
        return 1
    fi

    # Parse the response
    local status=$(echo "$sauron_data" | grep "^STATUS:" | cut -d: -f2)

    case "$status" in
        "running")
            echo "**Status:** [OK] Running"
            echo ""

            local mem=$(echo "$sauron_data" | grep "^MEM:" | cut -d: -f2)
            local cpu=$(echo "$sauron_data" | grep "^CPU:" | cut -d: -f2)
            local alerts=$(echo "$sauron_data" | grep "^ALERTS:" | cut -d: -f2)

            echo "| Metric | Value |"
            echo "|--------|-------|"
            echo "| Memory | $mem |"
            echo "| CPU | $cpu |"
            echo "| Total Alerts | $alerts |"
            echo ""

            if [[ "$alerts" -gt 0 ]]; then
                echo "**Recent Detections:**"
                echo ""
                echo "| Timestamp | File | Rule |"
                echo "|-----------|------|------|"
                echo "$sauron_data" | sed -n '/DETECTIONS_START/,/DETECTIONS_END/p' | grep "^|"
                echo ""
            else
                echo "[OK] No malware detected"
                echo ""
            fi
            ;;
        "stopped")
            echo "**Status:** [WARN] Container stopped"
            echo ""
            echo '```bash'
            echo "ssh $ssh_user@$vm_ip 'cd /opt/sauron && docker-compose up -d sauron'"
            echo '```'
            echo ""
            ;;
        "not_installed")
            echo "**Status:** [INFO] Sauron not installed"
            echo ""
            ;;
        *)
            echo "**Status:** [WARN] Unknown state"
            echo ""
            ;;
    esac
}

# Check each VM
for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"

    # Determine SSH user based on provider
    if [[ "$vm_name" == gcp-* ]]; then
        ssh_user="diego"
    else
        ssh_user="ubuntu"
    fi

    collect_sauron_report "$vm_name" "$vm_ip" "$ssh_user"
done

# Summary
echo "### Summary"
echo ""

total_alerts=0
active_scanners=0

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"

    if [[ "$vm_name" == gcp-* ]]; then
        ssh_user="diego"
    else
        ssh_user="ubuntu"
    fi

    ssh_key=$(get_ssh_key "$vm_name")
    result=$(ssh $SSH_OPTS -i "$ssh_key" "$ssh_user@$vm_ip" '
        if docker ps --filter "name=sauron" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
            alerts=$(docker exec sauron cat /var/log/sauron/alerts.jsonl 2>/dev/null | grep -c "detected.*true" || echo "0")
            echo "running:$alerts"
        else
            echo "down:0"
        fi
    ' 2>/dev/null)

    if [[ "$result" == running:* ]]; then
        ((active_scanners++))
        alerts=${result#running:}
        alerts=$(echo "$alerts" | tr -d '\n\r' | grep -oE '^[0-9]+' || echo "0")
        ((total_alerts += alerts))
    fi
done

echo "| Metric | Value |"
echo "|--------|-------|"
echo "| Active Scanners | $active_scanners / ${#VMS[@]} |"
echo "| Total Alerts | $total_alerts |"

if [[ $total_alerts -gt 0 ]]; then
    echo ""
    echo "**[FAIL] Malware detected - review alerts above**"
fi

