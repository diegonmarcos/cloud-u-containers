#!/bin/bash
#
# External Connectivity Checks
# Tests all endpoints from outside (HTTP, ports, DNS)
#

# VM IPs
OCI_MICRO_1="${OCI_MICRO_1:-130.110.251.193}"
OCI_MICRO_2="${OCI_MICRO_2:-129.151.228.66}"
GCP_MICRO_1="${GCP_MICRO_1:-35.226.147.64}"
OCI_FLEX_1="${OCI_FLEX_1:-84.235.234.87}"

# Counters
ok_count=0
fail_count=0
warn_count=0

check_port() {
    local name="$1"
    local host="$2"
    local port="$3"

    if timeout 5 nc -z "$host" "$port" 2>/dev/null; then
        ((ok_count++))
        echo "  - ✅ $name"
        return 0
    else
        ((fail_count++))
        echo "  - ❌ $name"
        return 1
    fi
}

check_http() {
    local name="$1"
    local url="$2"
    local expected="${3:-200}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -L "$url" 2>/dev/null || echo "000")

    if [[ "$status" == "200" ]] || [[ "$status" == "302" ]]; then
        ((ok_count++))
        echo "  - ✅ $name"
        return 0
    elif [[ "$status" == "525" ]]; then
        ((warn_count++))
        echo "  - ⚠️ $name - HTTP $status"
        return 1
    else
        ((fail_count++))
        echo "  - ❌ $name"
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
        ((ok_count++))
        echo "  - ✅ $name → $type record"
        return 0
    else
        ((fail_count++))
        echo "  - ❌ $name → Missing"
        return 1
    fi
}

cat << 'EOF'

## 1️⃣ External Connectivity

Tests all services from the **outside** (as users would access them)

### VM SSH Accessibility (4 checks)

EOF

check_port "OCI Micro 1 (Mail) - Port 22" "$OCI_MICRO_1" "22"
check_port "OCI Micro 2 (Analytics) - Port 22" "$OCI_MICRO_2" "22"
check_port "GCP Micro 1 (Proxy) - Port 22" "$GCP_MICRO_1" "22"
check_port "OCI Flex 1 (Photos) - Port 22 (sleeping)" "$OCI_FLEX_1" "22"

cat << 'EOF'

### Web Services HTTPS (7 checks)

EOF

check_http "analytics.diegonmarcos.com (Matomo)" "https://analytics.diegonmarcos.com"
check_http "proxy.diegonmarcos.com (NPM Admin)" "https://proxy.diegonmarcos.com"
check_http "auth.diegonmarcos.com (Authelia 2FA)" "https://auth.diegonmarcos.com"
check_http "mail.diegonmarcos.com/webmail (Roundcube)" "https://mail.diegonmarcos.com/webmail" "302"
check_http "cloud.diegonmarcos.com (Dashboard)" "https://cloud.diegonmarcos.com"
check_http "photos.app.diegonmarcos.com (VM sleeping)" "https://photos.app.diegonmarcos.com"
check_http "sync.diegonmarcos.com (VM sleeping)" "https://sync.diegonmarcos.com"

cat << 'EOF'

### Mail Server Ports (3 checks)

EOF

check_port "Port 465 (SMTPS) - Encrypted submission" "$OCI_MICRO_1" "465"
check_port "Port 993 (IMAPS) - Encrypted IMAP" "$OCI_MICRO_1" "993"
check_port "Port 8080 (SMTP Proxy) - HTTP relay" "$OCI_MICRO_1" "8080"

cat << 'EOF'

### DNS Record Validation (6 checks)

EOF

check_dns "mail.diegonmarcos.com" "mail.diegonmarcos.com" "A"
check_dns "diegonmarcos.com" "diegonmarcos.com" "MX"
check_dns "analytics.diegonmarcos.com" "analytics.diegonmarcos.com" "A"
check_dns "proxy.diegonmarcos.com" "proxy.diegonmarcos.com" "A"
check_dns "auth.diegonmarcos.com" "auth.diegonmarcos.com" "A"
check_dns "photos.app.diegonmarcos.com" "photos.app.diegonmarcos.com" "A"

echo ""
echo "**Total External Checks: 20** | ✅ OK: $ok_count | ⚠️ WARN: $warn_count | ❌ FAIL: $fail_count"
echo ""
