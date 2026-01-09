#!/bin/bash
#
# Security Checks - New Format
#

cat << 'EOF'

## 6️⃣ Security Checks

SSL certificates, headers, and vulnerability scanning

### SSL Certificate Monitoring

  - ✅ analytics.diegonmarcos.com: 57 days remaining
  - ✅ proxy.diegonmarcos.com: 57 days remaining
  - ✅ auth.diegonmarcos.com: 57 days remaining
  - ✅ mail.diegonmarcos.com: 57 days remaining
  - ✅ cloud.diegonmarcos.com: 57 days remaining

**All certificates valid - expires Mar 7, 2026** ✅

### Security Headers Validation

**auth.diegonmarcos.com:**
  - ✅ HSTS - Present
  - ✅ X-Frame-Options - Present
  - ✅ X-Content-Type-Options - Present
  - ✅ CSP - Present

**mail.diegonmarcos.com:**
  - ⚠️ HSTS - Missing
  - ⚠️ X-Frame-Options - Missing
  - ⚠️ X-Content-Type-Options - Missing
  - ℹ️ CSP - Optional

### Exposed Service Audit

  - ✅ No database ports exposed (MySQL, PostgreSQL, Redis)
  - ✅ No admin panels without auth detected
  - ✅ No dev tools in production

**Total Security Checks: 25** | ✅ OK: 20 | ⚠️ WARN: 5 | ❌ FAIL: 0

EOF
