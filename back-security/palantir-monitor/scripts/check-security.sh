#!/bin/bash
#
# Security Checks
# SSL certificates, vulnerabilities, exposed services
#

cat << EOF

## Security Checks

### SSL Certificate Status

| Domain | Expiry | Status |
|--------|--------|--------|
EOF

check_ssl() {
    local domain="$1"
    local port="${2:-443}"

    local expiry
    expiry=$(echo | timeout 5 openssl s_client -servername "$domain" -connect "$domain:$port" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    if [[ -n "$expiry" ]]; then
        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [[ $days_left -lt 0 ]]; then
            echo "| $domain | $expiry | [FAIL] Expired |"
        elif [[ $days_left -lt 7 ]]; then
            echo "| $domain | $expiry | [FAIL] Expires in $days_left days |"
        elif [[ $days_left -lt 30 ]]; then
            echo "| $domain | $expiry | [WARN] Expires in $days_left days |"
        else
            echo "| $domain | $expiry | [OK] $days_left days |"
        fi
    else
        echo "| $domain | - | [FAIL] Could not check |"
    fi
}

check_ssl "analytics.diegonmarcos.com"
check_ssl "proxy.diegonmarcos.com"
check_ssl "auth.diegonmarcos.com"
check_ssl "mail.diegonmarcos.com"
check_ssl "cloud.diegonmarcos.com"
check_ssl "photos.app.diegonmarcos.com"

cat << EOF

### Security Headers

EOF

check_headers() {
    local url="$1"
    local headers
    headers=$(curl -sI -m 10 "$url" 2>/dev/null)

    echo "**$url**"
    echo ""
    echo "| Header | Status |"
    echo "|--------|--------|"

    if echo "$headers" | grep -qi "strict-transport-security"; then
        echo "| HSTS | [OK] Present |"
    else
        echo "| HSTS | [WARN] Missing |"
    fi

    if echo "$headers" | grep -qi "x-frame-options"; then
        echo "| X-Frame-Options | [OK] Present |"
    else
        echo "| X-Frame-Options | [WARN] Missing |"
    fi

    if echo "$headers" | grep -qi "x-content-type-options"; then
        echo "| X-Content-Type-Options | [OK] Present |"
    else
        echo "| X-Content-Type-Options | [WARN] Missing |"
    fi

    if echo "$headers" | grep -qi "content-security-policy"; then
        echo "| CSP | [OK] Present |"
    else
        echo "| CSP | - (Optional) |"
    fi

    echo ""
}

check_headers "https://auth.diegonmarcos.com"
check_headers "https://mail.diegonmarcos.com"

cat << EOF

### Exposed Services (Potential Issues)

EOF

echo "| Service | Port | Risk |"
echo "|---------|------|------|"

# Check for potentially risky exposed ports
OCI_MICRO_1="${OCI_MICRO_1:-130.110.251.193}"
GCP_MICRO_1="${GCP_MICRO_1:-35.226.147.64}"

for ip in "$OCI_MICRO_1" "$GCP_MICRO_1"; do
    for port in 3306 5432 6379 27017 9200; do
        if timeout 2 nc -z "$ip" "$port" 2>/dev/null; then
            case $port in
                3306) echo "| MySQL ($ip) | $port | [FAIL] Database exposed |" ;;
                5432) echo "| PostgreSQL ($ip) | $port | [FAIL] Database exposed |" ;;
                6379) echo "| Redis ($ip) | $port | [FAIL] Redis exposed |" ;;
                27017) echo "| MongoDB ($ip) | $port | [FAIL] MongoDB exposed |" ;;
                9200) echo "| Elasticsearch ($ip) | $port | [FAIL] ES exposed |" ;;
            esac
        fi
    done
done

echo "| (scan complete) | - | - |"

cat << EOF

### Container Security

EOF

if [[ -S /var/run/docker.sock ]]; then
    echo "| Container | User | Privileged |"
    echo "|-----------|------|------------|"

    docker ps --format "{{.Names}}" 2>/dev/null | while read name; do
        user=$(docker inspect "$name" --format '{{.Config.User}}' 2>/dev/null)
        priv=$(docker inspect "$name" --format '{{.HostConfig.Privileged}}' 2>/dev/null)

        user_status="[OK] $user"
        [[ -z "$user" || "$user" == "root" ]] && user_status="[WARN] root"

        priv_status="[OK] No"
        [[ "$priv" == "true" ]] && priv_status="[FAIL] Yes"

        echo "| $name | $user_status | $priv_status |"
    done
else
    echo "(docker socket not mounted)"
fi

