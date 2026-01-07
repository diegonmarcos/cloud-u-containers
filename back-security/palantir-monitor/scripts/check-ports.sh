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

cat << EOF

### Container Port Mappings

EOF

if [[ -S /var/run/docker.sock ]]; then
    echo "**Published Ports (Host -> Container):**"
    echo ""
    echo "| Container | Host Port | Container Port | Protocol | Public |"
    echo "|-----------|-----------|----------------|----------|--------|"

    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        port_mappings=$(docker inspect "$name" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null)

        if [[ -n "$port_mappings" && "$port_mappings" != "null" && "$port_mappings" != "{}" ]]; then
            echo "$port_mappings" | jq -r 'to_entries[] | select(.value != null) | .key as $cport | .value[] | "\($cport)|\(.HostIp)|\(.HostPort)"' 2>/dev/null | while IFS='|' read cport hostip hostport; do
                container_port=$(echo "$cport" | cut -d'/' -f1)
                protocol=$(echo "$cport" | cut -d'/' -f2)

                # Check if publicly accessible
                public_status="[OK] Local"
                if [[ "$hostip" == "0.0.0.0" || "$hostip" == "::" || -z "$hostip" ]]; then
                    public_status="[WARN] Public"
                fi

                # Highlight sensitive ports
                port_status="$hostport"
                case "$container_port" in
                    3306|5432|6379|27017|9200)
                        port_status="[WARN] $hostport (DB)"
                        ;;
                    2375|2376)
                        port_status="[FAIL] $hostport (Docker API)"
                        ;;
                esac

                echo "| $name | $port_status | $container_port | $protocol | $public_status |"
            done
        fi
    done

    # Internal exposed ports (not published)
    echo ""
    echo "**Internal Exposed Ports (not published to host):**"
    echo ""
    echo "| Container | Internal Port | Protocol | Service Hint |"
    echo "|-----------|---------------|----------|--------------|"

    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        exposed=$(docker inspect "$name" --format '{{range $port, $_ := .Config.ExposedPorts}}{{$port}} {{end}}' 2>/dev/null)
        published=$(docker inspect "$name" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{if $bindings}}{{$port}} {{end}}{{end}}' 2>/dev/null)

        for port in $exposed; do
            # Check if this port is published
            is_published=0
            for pub in $published; do
                if [[ "$port" == "$pub" ]]; then
                    is_published=1
                    break
                fi
            done

            if [[ $is_published -eq 0 ]]; then
                port_num=$(echo "$port" | cut -d'/' -f1)
                protocol=$(echo "$port" | cut -d'/' -f2)

                # Guess service
                service=""
                case "$port_num" in
                    80) service="HTTP" ;;
                    443) service="HTTPS" ;;
                    3306) service="MySQL" ;;
                    5432) service="PostgreSQL" ;;
                    6379) service="Redis" ;;
                    27017) service="MongoDB" ;;
                    9200) service="Elasticsearch" ;;
                    8080) service="HTTP Alt" ;;
                    *) service="Unknown" ;;
                esac

                echo "| $name | $port_num | $protocol | $service |"
            fi
        done
    done

    # High port analysis
    echo ""
    echo "**High Port Usage Analysis (>1024):**"
    echo ""

    high_port_count=0
    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        docker inspect "$name" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null | \
            jq -r 'to_entries[] | select(.value != null) | .value[] | .HostPort' 2>/dev/null | while read port; do
            if [[ $port -gt 1024 ]]; then
                ((high_port_count++))
            fi
        done
    done

    if [[ $high_port_count -gt 0 ]]; then
        echo "- [INFO] $high_port_count high port(s) in use (>1024)"
        echo "  - High ports are generally safe but review for unexpected services"
    else
        echo "- [INFO] Only standard ports (<1024) are published"
    fi

else
    echo "(docker socket not mounted - cannot analyze container ports)"
fi

