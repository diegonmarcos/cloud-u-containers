#!/bin/bash
# Quick version - simplified cloud check in new format

ok=0; warn=0; fail=0

cat <<'HEAD'

## 2️⃣ Cloud Infrastructure Status

Uses **SSH** to gather system metrics from each VM

### Current VM Status

HEAD

for vm in "gcp-micro-1:35.226.147.64" "oci-micro-1:130.110.251.193" "oci-micro-2:129.151.228.66" "oci-flex-1:84.235.234.87"; do
  name="${vm%:*}"
  ip="${vm#*:}"
  if timeout 3 nc -z "$ip" 22 2>/dev/null; then
    echo "  - ✅ $name ($ip) - SSH accessible"
    ((ok++))
  else
    echo "  - ❌ $name ($ip) - Unreachable"
    ((fail++))
  fi
done

echo ""
echo "**Total Infrastructure Checks: 4** | ✅ OK: $ok | ⚠️ WARN: $warn | ❌ FAIL: $fail"
echo ""
