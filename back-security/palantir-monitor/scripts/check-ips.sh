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

### Docker Network IPs

EOF

if [[ -S /var/run/docker.sock ]]; then
    echo "| Container | Network | IP Address |"
    echo "|-----------|---------|------------|"

    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        networks=$(docker inspect "$name" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}={{$conf.IPAddress}} {{end}}' 2>/dev/null)
        for net_ip in $networks; do
            net="${net_ip%%=*}"
            ip="${net_ip##*=}"
            if [[ -n "$ip" ]]; then
                echo "| $name | $net | $ip |"
            fi
        done
    done
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

