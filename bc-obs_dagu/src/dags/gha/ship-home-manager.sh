#!/usr/bin/env bash
# ── Deploy home-manager to a VM ──
# Usage: ship-home-manager.sh <vm-alias>
#   Omit vm to deploy to all VMs
set -euo pipefail

VM="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

VMS="${VM:-gcp-proxy gcp-t4 oci-mail oci-analytics oci-apps}"
OK=0; FAIL=0

for vm in $VMS; do
  HM_DIR="b_infra/home-manager/${vm}"
  if [ ! -d "$HM_DIR" ]; then
    echo "SKIP $vm (no home-manager dir)"
    continue
  fi
  echo "── Ship home-manager: $vm ──"
  if bash "${HM_DIR}/build.sh" ship; then
    echo "OK $vm"
    OK=$((OK + 1))
  else
    echo "FAIL $vm (exit $?)"
    FAIL=$((FAIL + 1))
  fi
done

echo "Home-manager: $OK ok, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
