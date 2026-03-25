#!/usr/bin/env bash
# ── Trigger health checks for all VMs ──
# Usage: health-all-vms.sh
# In GHA: triggers per-VM workflow_dispatch via gh CLI
# In CLI/Dagu: runs health-check-vm.sh directly for each VM
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VMS="gcp-proxy gcp-t4 oci-apps oci-analytics oci-mail"

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  # In GHA: trigger individual workflows
  REPO="${GITHUB_REPOSITORY:-diegonmarcos/cloud}"
  for vm in $VMS; do
    echo "Triggering health-${vm}.yml"
    gh workflow run "health-${vm}.yml" --repo "$REPO" --ref main || echo "WARN: failed to trigger $vm"
  done
  gh workflow run "health-http-public.yml" --repo "$REPO" --ref main || true
  gh workflow run "health-http-private.yml" --repo "$REPO" --ref main || true
else
  # In CLI/Dagu: run health-check-vm.sh directly
  for vm in $VMS; do
    echo "── Health: $vm ──"
    bash "$SCRIPT_DIR/health-check-vm.sh" "$vm" || echo "FAIL: $vm"
  done
fi
