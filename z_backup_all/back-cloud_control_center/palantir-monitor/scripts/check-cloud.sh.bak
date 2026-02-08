#!/bin/bash
#
# Cloud Provider Checks (Lite)
# Uses SSH to VMs instead of heavy OCI/GCloud CLIs
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

get_ssh_user() {
    local vm_name="$1"
    if [[ "$vm_name" == gcp-* ]]; then
        echo "diego"
    else
        echo "ubuntu"
    fi
}

get_ssh_key() {
    local vm_name="$1"
    if [[ "$vm_name" == gcp-* ]]; then
        echo "$SSH_KEY_GCP"
    else
        echo "$SSH_KEY_OCI"
    fi
}

cat << EOF

## Cloud Infrastructure Status

### VM Health (via SSH)

| VM | IP | Status | Uptime | Load | Memory |
|----|-----|--------|--------|------|--------|
EOF

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"
    ssh_user=$(get_ssh_user "$vm_name")
    ssh_key=$(get_ssh_key "$vm_name")

    # Check if reachable
    if ! timeout 5 nc -z "$vm_ip" 22 2>/dev/null; then
        echo "| $vm_name | $vm_ip | [FAIL] Unreachable | - | - | - |"
        continue
    fi

    # Get system info via SSH
    info=$(ssh $SSH_OPTS -i "$ssh_key" "$ssh_user@$vm_ip" '
        uptime_str=$(uptime -p 2>/dev/null || uptime | sed "s/.*up/up/")
        load=$(cat /proc/loadavg | cut -d" " -f1-3)
        mem_total=$(free -m | awk "/Mem:/ {print \$2}")
        mem_used=$(free -m | awk "/Mem:/ {print \$3}")
        mem_pct=$((mem_used * 100 / mem_total))
        echo "$uptime_str|$load|${mem_used}/${mem_total}MB (${mem_pct}%)"
    ' 2>/dev/null)

    if [[ -n "$info" ]]; then
        uptime_str=$(echo "$info" | cut -d'|' -f1)
        load=$(echo "$info" | cut -d'|' -f2)
        mem=$(echo "$info" | cut -d'|' -f3)
        echo "| $vm_name | $vm_ip | [OK] | $uptime_str | $load | $mem |"
    else
        echo "| $vm_name | $vm_ip | [WARN] SSH failed | - | - | - |"
    fi
done

cat << EOF

### Disk Usage

| VM | Filesystem | Size | Used | Avail | Use% |
|----|------------|------|------|-------|------|
EOF

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"
    ssh_user=$(get_ssh_user "$vm_name")
    ssh_key=$(get_ssh_key "$vm_name")

    disk_info=$(ssh $SSH_OPTS -i "$ssh_key" "$ssh_user@$vm_ip" '
        df -h / | tail -1 | awk "{print \$2\"|\"\$3\"|\"\$4\"|\"\$5}"
    ' 2>/dev/null)

    if [[ -n "$disk_info" ]]; then
        size=$(echo "$disk_info" | cut -d'|' -f1)
        used=$(echo "$disk_info" | cut -d'|' -f2)
        avail=$(echo "$disk_info" | cut -d'|' -f3)
        pct=$(echo "$disk_info" | cut -d'|' -f4)

        # Warn if over 80%
        pct_num=${pct%\%}
        status="$pct"
        [[ "$pct_num" -gt 90 ]] && status="[FAIL] $pct"
        [[ "$pct_num" -gt 80 && "$pct_num" -le 90 ]] && status="[WARN] $pct"

        echo "| $vm_name | / | $size | $used | $avail | $status |"
    fi
done

cat << EOF

### Docker Status per VM

EOF

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"
    ssh_user=$(get_ssh_user "$vm_name")
    ssh_key=$(get_ssh_key "$vm_name")

    echo "#### $vm_name ($vm_ip)"
    echo ""

    docker_info=$(ssh $SSH_OPTS -i "$ssh_key" "$ssh_user@$vm_ip" '
        if command -v docker &>/dev/null; then
            running=$(docker ps -q 2>/dev/null | wc -l)
            stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l)
            echo "running:$running|stopped:$stopped"
            echo "CONTAINERS:"
            docker ps --format "| {{.Names}} | {{.Image}} | {{.Status}} |" 2>/dev/null
        else
            echo "NO_DOCKER"
        fi
    ' 2>/dev/null)

    if [[ "$docker_info" == "NO_DOCKER" ]]; then
        echo "[INFO] Docker not installed"
    elif [[ -n "$docker_info" ]]; then
        stats=$(echo "$docker_info" | head -1)
        running=$(echo "$stats" | grep -oP 'running:\K\d+')
        stopped=$(echo "$stats" | grep -oP 'stopped:\K\d+')

        echo "**Containers:** $running running, $stopped stopped"
        echo ""
        echo "| Name | Image | Status |"
        echo "|------|-------|--------|"
        echo "$docker_info" | grep "^|"
    else
        echo "[WARN] Could not get Docker status"
    fi
    echo ""
done

