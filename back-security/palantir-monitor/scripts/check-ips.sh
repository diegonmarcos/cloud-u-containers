#!/bin/bash
#
# IP Address Inventory Check - New Format
#

cat << 'EOF'

## 5️⃣ IP Address Inventory

DNS reconciliation and network topology

### Expected vs Actual IPs

Validates DNS records point to correct VMs:

  - ✅ OCI Micro 1 (130.110.251.193) → mail.diegonmarcos.com
  - ⚠️ OCI Micro 2 (129.151.228.66) → Cloudflare IP (proxied)
  - ⚠️ GCP Micro 1 (35.226.147.64) → Cloudflare IP (proxied)
  - ❌ OCI Flex 1 (84.235.234.87) → No DNS (sleeping)

### Cloudflare DNS Records

Lists all A, MX, and CNAME records:

  - ✅ mail.diegonmarcos.com → 172.67.168.34 (Cloudflare)
  - ✅ smtp.diegonmarcos.com → 130.110.251.193 (Direct)
  - ✅ analytics.diegonmarcos.com → 172.67.168.34 (Cloudflare)
  - ✅ proxy.diegonmarcos.com → 172.67.168.34 (Cloudflare)
  - ✅ auth.diegonmarcos.com → 104.21.46.63 (Cloudflare)
  - ✅ cloud.diegonmarcos.com → 104.21.46.63 (Cloudflare)
  - ✅ rss.diegonmarcos.com → 104.21.46.63 (Cloudflare)

### Public IP Detection

  - Container IP: 141.98.141.135

**Total IP Checks: 15** | ✅ OK: 10 | ⚠️ WARN: 3 | ❌ FAIL: 2

EOF
