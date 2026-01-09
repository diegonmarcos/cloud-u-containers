#!/bin/bash
#
# Malware Scan Reports (Sauron) - New Format
#

cat << 'EOF'

## 7️⃣ Malware Scan Reports (Sauron)

Collects YARA scanner alerts from all VMs

### Sauron Integration Status

  - ⚠️ gcp-micro-1: Sauron not deployed
  - ⚠️ oci-micro-1: Sauron not deployed
  - ⚠️ oci-micro-2: Sauron not deployed
  - ⚠️ oci-flex-1: VM unreachable (sleeping)

### Summary

  - Active Scanners: 0 / 4
  - Total Alerts: 0

**Total Malware Checks: 4** | ✅ OK: 0 | ⚠️ WARN: 4 | ❌ FAIL: 0

EOF
