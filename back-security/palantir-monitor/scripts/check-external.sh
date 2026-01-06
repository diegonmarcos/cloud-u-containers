#!/bin/bash
#
# External Connectivity Checks
# Tests all endpoints from outside (HTTP, ports, DNS)
#

# VM IPs
OCI_MICRO_1="${OCI_MICRO_1:-130.110.251.193}"  # Mailu
OCI_MICRO_2="${OCI_MICRO_2:-129.151.228.66}"   # Matomo
GCP_MICRO_1="${GCP_MICRO_1:-35.226.147.64}"    # NPM/Authelia
OCI_FLEX_1="${OCI_FLEX_1:-84.235.234.87}"      # Photoprism

check_port() {
    local name="$1"
    local host="$2"
    local port="$3"

    if timeout 5 nc -z "$host" "$port" 2>/dev/null; then
        echo "| $name | $host:$port | [OK] |"
        return 0
    else
        echo "| $name | $host:$port | [FAIL] |"
        return 1
    fi
}

check_http() {
    local name="$1"
    local url="$2"
    local expected="${3:-200}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -L "$url" 2>/dev/null || echo "000")

    if [[ "$status" == "$expected" ]] || [[ "$status" == "301" ]] || [[ "$status" == "302" ]] || [[ "$status" == "200" ]]; then
        echo "| $name | $url | [OK] ($status) |"
        return 0
    else
        echo "| $name | $url | [FAIL] ($status) |"
        return 1
    fi
}

check_dns() {
    local name="$1"
    local domain="$2"
    local type="${3:-A}"

    local result
    result=$(dig +short "$domain" "$type" 2>/dev/null | head -1)

    if [[ -n "$result" ]]; then
        echo "| $name | $domain ($type) | [OK] $result |"
        return 0
    else
        echo "| $name | $domain ($type) | [FAIL] No record |"
        return 1
    fi
}

cat << EOF

## External Connectivity

### VM SSH Ports (Port 22)

| Server | Endpoint | Status |
|--------|----------|--------|
EOF

check_port "OCI Micro 1 (Mail)" "$OCI_MICRO_1" "22"
check_port "OCI Micro 2 (Analytics)" "$OCI_MICRO_2" "22"
check_port "GCP Micro 1 (Proxy)" "$GCP_MICRO_1" "22"
check_port "OCI Flex 1 (Photos)" "$OCI_FLEX_1" "22"

cat << EOF

### Web Services (HTTPS)

| Service | URL | Status |
|---------|-----|--------|
EOF

check_http "Analytics (Matomo)" "https://analytics.diegonmarcos.com"
check_http "Proxy Admin (NPM)" "https://proxy.diegonmarcos.com"
check_http "Auth (Authelia)" "https://auth.diegonmarcos.com"
check_http "Mail Webmail" "https://mail.diegonmarcos.com/webmail" "302"
check_http "Cloud Dashboard" "https://cloud.diegonmarcos.com"
check_http "Photos App" "https://photos.app.diegonmarcos.com"
check_http "Sync" "https://sync.diegonmarcos.com"

cat << EOF

### Mail Ports

| Service | Endpoint | Status |
|---------|----------|--------|
EOF

check_port "SMTPS (465)" "$OCI_MICRO_1" "465"
check_port "IMAPS (993)" "$OCI_MICRO_1" "993"
check_port "SMTP Proxy (8080)" "$OCI_MICRO_1" "8080"

cat << EOF

### DNS Records

| Record | Domain | Status |
|--------|--------|--------|
EOF

check_dns "Mail A" "mail.diegonmarcos.com" "A"
check_dns "Mail MX" "diegonmarcos.com" "MX"
check_dns "Analytics" "analytics.diegonmarcos.com" "A"
check_dns "Proxy" "proxy.diegonmarcos.com" "A"
check_dns "Auth" "auth.diegonmarcos.com" "A"
check_dns "Photos" "photos.app.diegonmarcos.com" "A"

echo ""
