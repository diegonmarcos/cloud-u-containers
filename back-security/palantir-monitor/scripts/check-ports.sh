#!/bin/bash
#
# Port Analysis (Lite)
# External port scanning - no local docker socket required
#

# VM Configuration
declare -A VMS=(
    ["oci-micro-1"]="130.110.251.193"
    ["oci-micro-2"]="129.151.228.66"
    ["gcp-micro-1"]="35.226.147.64"
    ["oci-flex-1"]="84.235.234.87"
)

# Expected ports per VM
declare -A EXPECTED_PORTS=(
    ["oci-micro-1"]="22 25 80 443 465 587 993 8080"   # Mail
    ["oci-micro-2"]="22 80 443"                        # Matomo
    ["gcp-micro-1"]="22 80 81 443"                     # NPM/Authelia
    ["oci-flex-1"]="22 80 443 5232 8384"               # Photos/Sync/Cal
)

# Port descriptions
declare -A PORT_NAMES=(
    [22]="SSH"
    [25]="SMTP"
    [80]="HTTP"
    [81]="NPM Admin"
    [443]="HTTPS"
    [465]="SMTPS"
    [587]="Submission"
    [993]="IMAPS"
    [5232]="Radicale"
    [8080]="SMTP Proxy"
    [8384]="Syncthing"
)

cat << EOF

## Port Analysis

### Port Scan per VM

EOF

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"
    expected="${EXPECTED_PORTS[$vm_name]}"

    echo "#### $vm_name ($vm_ip)"
    echo ""
    echo "| Port | Service | Expected | Status |"
    echo "|------|---------|----------|--------|"

    for port in $expected; do
        service="${PORT_NAMES[$port]:-Unknown}"

        if timeout 3 nc -z "$vm_ip" "$port" 2>/dev/null; then
            echo "| $port | $service | Yes | [OK] Open |"
        else
            echo "| $port | $service | Yes | [FAIL] Closed |"
        fi
    done

    echo ""
done

cat << EOF

### Unexpected Open Ports

Scanning for common risky ports...

| VM | Port | Service | Status |
|----|------|---------|--------|
EOF

# Check for unexpected/risky ports
risky_ports="3306 5432 6379 27017 9200 2375 2376"

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"

    for port in $risky_ports; do
        if timeout 2 nc -z "$vm_ip" "$port" 2>/dev/null; then
            case $port in
                3306) service="MySQL" ;;
                5432) service="PostgreSQL" ;;
                6379) service="Redis" ;;
                27017) service="MongoDB" ;;
                9200) service="Elasticsearch" ;;
                2375) service="Docker (unencrypted)" ;;
                2376) service="Docker (TLS)" ;;
            esac
            echo "| $vm_name | $port | $service | [FAIL] Exposed! |"
        fi
    done
done

echo "| (scan complete) | - | - | - |"

