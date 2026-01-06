#!/bin/bash
#
# Docker Container Checks (Lite)
# Note: Detailed Docker status is now in check-cloud.sh via SSH
# This script provides a quick summary across all VMs
#

# VM Configuration
declare -A VMS=(
    ["oci-micro-1"]="130.110.251.193"
    ["oci-micro-2"]="129.151.228.66"
    ["gcp-micro-1"]="35.226.147.64"
    ["oci-flex-1"]="84.235.234.87"
)

SSH_KEY="${SSH_KEY:-/root/.ssh/id_rsa}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

get_ssh_user() {
    if [[ "$1" == gcp-* ]]; then echo "diego"; else echo "ubuntu"; fi
}

cat << EOF

## Docker Summary (All VMs)

| VM | Running | Stopped | Unhealthy | Images |
|----|---------|---------|-----------|--------|
EOF

total_running=0
total_stopped=0
total_unhealthy=0

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"
    ssh_user=$(get_ssh_user "$vm_name")

    stats=$(ssh $SSH_OPTS -i "$SSH_KEY" "$ssh_user@$vm_ip" '
        if command -v docker &>/dev/null; then
            running=$(docker ps -q 2>/dev/null | wc -l)
            stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l)
            unhealthy=$(docker ps --filter "health=unhealthy" -q 2>/dev/null | wc -l)
            images=$(docker images -q 2>/dev/null | wc -l)
            echo "$running|$stopped|$unhealthy|$images"
        else
            echo "N/A|N/A|N/A|N/A"
        fi
    ' 2>/dev/null)

    if [[ -n "$stats" && "$stats" != "N/A|N/A|N/A|N/A" ]]; then
        running=$(echo "$stats" | cut -d'|' -f1)
        stopped=$(echo "$stats" | cut -d'|' -f2)
        unhealthy=$(echo "$stats" | cut -d'|' -f3)
        images=$(echo "$stats" | cut -d'|' -f4)

        # Status indicators
        unhealthy_status="$unhealthy"
        [[ "$unhealthy" -gt 0 ]] && unhealthy_status="[FAIL] $unhealthy"

        echo "| $vm_name | $running | $stopped | $unhealthy_status | $images |"

        ((total_running += running))
        ((total_stopped += stopped))
        ((total_unhealthy += unhealthy))
    else
        echo "| $vm_name | - | - | - | - |"
    fi
done

echo "| **Total** | **$total_running** | **$total_stopped** | **$total_unhealthy** | - |"

if [[ $total_unhealthy -gt 0 ]]; then
    echo ""
    echo "**[FAIL] $total_unhealthy unhealthy container(s) detected**"
fi

