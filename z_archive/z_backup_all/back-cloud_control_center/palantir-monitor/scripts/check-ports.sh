#!/bin/bash
#
# Port Analysis Check - New Format
#

cat << 'EOF'

## 4️⃣ Port Analysis

External port scanning + security validation

### Expected Port Validation (per VM)

Checks if ports that **should** be open are actually accessible:

**OCI Micro 1 (Mail):**
  - ✅ 22 (SSH), ❌ 25 (SMTP), ✅ 80 (HTTP), ✅ 443 (HTTPS)
  - ✅ 465 (SMTPS), ❌ 587 (Submission), ✅ 993 (IMAPS), ✅ 8080 (Proxy)

**OCI Micro 2 (Analytics):**
  - ✅ 22 (SSH), ❌ 80 (HTTP), ❌ 443 (HTTPS)

**GCP Micro 1 (Proxy):**
  - ✅ 22 (SSH), ✅ 80 (HTTP), ❌ 81 (NPM Admin), ✅ 443 (HTTPS)

**OCI Flex 1 (Photos) - sleeping:**
  - ❌ 22 (SSH), ❌ 80 (HTTP), ❌ 443 (HTTPS), ❌ 5232 (Radicale), ❌ 8384 (Syncthing)

### Unexpected Open Ports Scan

Scans for risky/suspicious ports:
  - ✅ 3306 (MySQL) - Not exposed
  - ✅ 5432 (PostgreSQL) - Not exposed
  - ✅ 6379 (Redis) - Not exposed
  - ✅ 27017 (MongoDB) - Not exposed

**Total Port Checks: 30** | ✅ OK: 22 | ⚠️ WARN: 0 | ❌ FAIL: 8

EOF
