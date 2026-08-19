#!/usr/bin/env bash
# ── Ship all services for a VM ──
# Portable: works in GHA, Dagu, CLI
# Usage: cloud-ship-orchestrate-vm.sh <vm-alias> [service-filter]
#   vm-alias: gcp-proxy, oci-apps, oci-mail, oci-analytics, gcp-t4
#   service-filter: optional, only ship this service dir (e.g. bc-obs_dagu)
set -euo pipefail

VM="${1:?Usage: cloud-ship-orchestrate-vm.sh <vm-alias> [service-filter]}"
FILTER="${2:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# 2026-04-27 migrated: cloud-data-gha-config.json -> _cloud-data-consolidated.json[._gha]
CONS=""
for p in "1_cloud-configs/dist/_cloud-data-consolidated.json" \
         "/var/lib/dagu/data/cloud-data/_cloud-data-consolidated.json" \
         "/var/lib/dagu/data/cloud-data/1_cloud-configs/dist/_cloud-data-consolidated.json" \
         "/app/_cloud-data-consolidated.json"; do
  [ -f "$p" ] && CONS="$p" && break
done
GHA_CONFIG=""
if [ -n "$CONS" ]; then
  GHA_CONFIG="${RUNNER_TEMP:-/tmp}/derived-gha-config.$$.json"
  jq '._gha' "$CONS" > "$GHA_CONFIG"
else
  for p in "1_cicd/dist/cloud-data-gha-config.json" \
           "/var/lib/dagu/data/cloud-data/cloud-data-gha-config.json" \
           "/var/lib/dagu/data/cloud-data/1_cicd/dist/cloud-data-gha-config.json" \
           "/app/cloud-data-gha-config.json"; do
    [ -f "$p" ] && GHA_CONFIG="$p" && break
  done
fi
if [ -z "$GHA_CONFIG" ]; then
  echo "ERROR: _cloud-data-consolidated.json (or legacy cloud-data-gha-config.json) not found in any known location" >&2
  exit 1
fi

# Get services for this VM
SERVICES=$(jq -r --arg vm "$VM" '
  .services | to_entries[]
  | select(.value.vm == $vm)
  | [.value.dir, .key, (.value.has_docker // false | tostring)]
  | join("|")
' "$GHA_CONFIG")

if [ -z "$SERVICES" ]; then
  echo "No services found for VM: $VM"
  exit 0
fi

# Detect changed dirs (GHA provides HEAD~1, CLI/Dagu ships all)
CHANGED_DIRS=""
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" ]; then
  CHANGED_DIRS=$(git diff --name-only HEAD~1 HEAD -- 'a_solutions/*/src/' 2>/dev/null | awk -F/ '{print $2}' | sort -u | tr '\n' ' ')
fi

OK=0
FAIL=0
SKIP=0
TOTAL=$(echo "$SERVICES" | wc -l)

echo "═══════════════════════════════════════════════"
echo "Ship → $VM ($TOTAL services)"
echo "═══════════════════════════════════════════════"

echo "$SERVICES" | while IFS='|' read -r dir name has_docker; do
  # Apply filter
  if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  # Skip unchanged (only in GHA push events)
  if [ -n "$CHANGED_DIRS" ] && ! echo "$CHANGED_DIRS" | grep -q "$dir"; then
    echo "SKIP $name (unchanged)"
    SKIP=$((SKIP + 1))
    continue
  fi

  BUILD_SH="a_solutions/${dir}/build.sh"
  if [ ! -f "$BUILD_SH" ]; then
    echo "SKIP $name (no build.sh)"
    SKIP=$((SKIP + 1))
    continue
  fi

  echo ""
  echo "── Ship: $name ($dir) ──"

  # Set REMOTE_BUILD for Docker services
  if [ "$has_docker" = "true" ]; then
    export REMOTE_BUILD="true"
  else
    unset REMOTE_BUILD 2>/dev/null || true
  fi

  if bash "$BUILD_SH" ship; then
    echo "OK $name"
    OK=$((OK + 1))
  else
    echo "FAIL $name (exit $?)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "═══════════════════════════════════════════════"
echo "Ship → $VM: $OK ok, $FAIL failed, $SKIP skipped (of $TOTAL)"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
