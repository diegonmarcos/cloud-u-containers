#!/bin/bash
#
# IP Address Inventory
# Lists all current IPs for VMs and services
#

cat << EOF

## IP Address Inventory

### Expected IPs (from config)

| Resource | Expected IP | Current DNS |
|----------|-------------|-------------|
EOF

# Check DNS resolution matches expected
check_ip() {
    local name="$1"
    local expected="$2"
    local domain="$3"

    if [[ -n "$domain" ]]; then
        current=$(dig +short "$domain" A 2>/dev/null | head -1)
        if [[ "$current" == "$expected" ]]; then
            echo "| $name | $expected | [OK] $current |"
        elif [[ -n "$current" ]]; then
            echo "| $name | $expected | [WARN] $current (mismatch) |"
        else
            echo "| $name | $expected | [FAIL] No DNS |"
        fi
    else
        echo "| $name | $expected | (no domain) |"
    fi
}

# Main VMs
check_ip "OCI Micro 1 (Mail)" "130.110.251.193" "smtp.diegonmarcos.com"
check_ip "OCI Micro 2 (Matomo)" "129.151.228.66" "analytics.diegonmarcos.com"
check_ip "GCP Micro 1 (Proxy)" "35.226.147.64" "proxy.diegonmarcos.com"
check_ip "OCI Flex 1 (Photos)" "84.235.234.87" "photos.app.diegonmarcos.com"

cat << EOF

### Cloudflare DNS Records

EOF

echo '```'
echo "# A Records"
for domain in mail smtp analytics proxy auth cloud photos.app sync cal rss; do
    result=$(dig +short "${domain}.diegonmarcos.com" A 2>/dev/null | head -1)
    if [[ -n "$result" ]]; then
        printf "%-30s -> %s\n" "${domain}.diegonmarcos.com" "$result"
    else
        printf "%-30s -> (no record)\n" "${domain}.diegonmarcos.com"
    fi
done
echo ""
echo "# MX Records"
dig +short diegonmarcos.com MX 2>/dev/null
echo ""
echo "# CNAME Records"
for domain in mail www; do
    result=$(dig +short "${domain}.diegonmarcos.com" CNAME 2>/dev/null | head -1)
    if [[ -n "$result" ]]; then
        printf "%-30s -> %s\n" "${domain}.diegonmarcos.com (CNAME)" "$result"
    fi
done
echo '```'

cat << EOF

### Docker Network Analysis

EOF

if [[ -S /var/run/docker.sock ]]; then
    # Container IPs
    echo "**Container Network Assignments:**"
    echo ""
    echo "| Container | Network | IP Address | Gateway |"
    echo "|-----------|---------|------------|---------|"

    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        net_info=$(docker inspect "$name" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}|{{$conf.IPAddress}}|{{$conf.Gateway}} {{end}}' 2>/dev/null)
        for entry in $net_info; do
            net=$(echo "$entry" | cut -d'|' -f1)
            ip=$(echo "$entry" | cut -d'|' -f2)
            gw=$(echo "$entry" | cut -d'|' -f3)
            if [[ -n "$ip" ]]; then
                echo "| $name | $net | $ip | $gw |"
            fi
        done
    done

    # Network topology
    echo ""
    echo "**Network Topology:**"
    echo ""
    echo "| Network | Driver | Subnet | Containers |"
    echo "|---------|--------|--------|------------|"

    docker network ls --format "{{.Name}}" 2>/dev/null | while read net; do
        driver=$(docker network inspect "$net" --format '{{.Driver}}' 2>/dev/null)
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
        containers=$(docker network inspect "$net" --format '{{len .Containers}}' 2>/dev/null)

        # Skip default networks with no containers
        if [[ "$containers" -gt 0 || "$net" =~ (bridge|host|none) ]]; then
            subnet_display="${subnet:-none}"
            echo "| $net | $driver | $subnet_display | $containers |"
        fi
    done

    # Connectivity matrix
    echo ""
    echo "**Inter-Container Connectivity:**"
    echo ""
    echo "| Container A | Container B | Same Network | Status |"
    echo "|-------------|-------------|--------------|--------|"

    declare -A container_nets
    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        nets=$(docker inspect "$name" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null)
        container_nets[$name]="$nets"
    done

    # Check connectivity between containers
    containers=($(docker ps --format "{{.Names}}" 2>/dev/null))
    for ((i=0; i<${#containers[@]}; i++)); do
        for ((j=i+1; j<${#containers[@]}; j++)); do
            c1="${containers[$i]}"
            c2="${containers[$j]}"

            nets1=$(docker inspect "$c1" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null)
            nets2=$(docker inspect "$c2" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null)

            # Check for common networks
            shared_net=""
            for n1 in $nets1; do
                for n2 in $nets2; do
                    if [[ "$n1" == "$n2" ]]; then
                        shared_net="$n1"
                        break 2
                    fi
                done
            done

            if [[ -n "$shared_net" ]]; then
                echo "| $c1 | $c2 | $shared_net | [OK] Connected |"
            else
                echo "| $c1 | $c2 | - | [INFO] Isolated |"
            fi
        done
    done

    # Network isolation check
    echo ""
    echo "**Network Isolation Review:**"
    echo ""

    # Count containers in default bridge (potential security issue)
    bridge_count=$(docker network inspect bridge --format '{{len .Containers}}' 2>/dev/null || echo 0)
    if [[ $bridge_count -gt 0 ]]; then
        echo "- [WARN] $bridge_count container(s) using default bridge network"
        echo "  - Consider using custom networks for better isolation"
    else
        echo "- [OK] No containers on default bridge network"
    fi

    # Check for host network mode (security concern)
    host_count=$(docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        mode=$(docker inspect "$name" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)
        [[ "$mode" == "host" ]] && echo "$name"
    done | wc -l)

    if [[ $host_count -gt 0 ]]; then
        echo "- [WARN] $host_count container(s) using host network mode"
        echo "  - Host mode bypasses network isolation"
    else
        echo "- [OK] No containers using host network mode"
    fi

else
    echo "(docker socket not mounted)"
fi

cat << EOF

### Public IP Check

EOF

echo '```'
echo -n "Public IP (from this container): "
curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "Could not determine"
echo ""
echo '```'

