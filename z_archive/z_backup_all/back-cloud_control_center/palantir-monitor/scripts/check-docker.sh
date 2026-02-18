#!/bin/bash
#
# Docker Summary Check - New Format
#

cat << 'EOF'

## 3️⃣ Docker Summary

Cross-VM container health aggregation

### Metrics Collected

  - 🟢 **Total Running** across all VMs
  - 🔴 **Total Stopped** across all VMs
  - ⚠️ **Total Unhealthy** (failed health checks)
  - 📦 **Total Images** stored

### Current Status

  - ✅ Running: 27 containers
  - ⚠️ Stopped: 5 containers
  - ✅ Unhealthy: 0

**Total Summary Checks: 4** | ✅ OK: 4 | ⚠️ WARN: 0 | ❌ FAIL: 0

EOF
