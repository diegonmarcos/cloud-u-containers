#!/usr/bin/env bash
# ── Build + push all Docker images to GHCR ──
# Portable: works in GHA, Dagu, CLI
# Usage: ship-ghcr.sh [service-filter]
set -euo pipefail

FILTER="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

GHA_CONFIG="cloud-data/cloud-data-gha-config.json"
if [ ! -f "$GHA_CONFIG" ]; then
  echo "ERROR: $GHA_CONFIG not found" >&2
  exit 1
fi

# Get all Docker-enabled services
SERVICES=$(jq -r '
  .services | to_entries[]
  | select(.value.has_docker == true)
  | [.value.dir, .key, (.value.docker_image // "")]
  | join("|")
' "$GHA_CONFIG")

if [ -z "$SERVICES" ]; then
  echo "No Docker services found"
  exit 0
fi

OK=0
FAIL=0

echo "═══════════════════════════════════════════════"
echo "Ship → GHCR images"
echo "═══════════════════════════════════════════════"

echo "$SERVICES" | while IFS='|' read -r dir name image; do
  if [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ]; then
    continue
  fi

  BUILD_SH="a_solutions/${dir}/build.sh"
  if [ ! -f "$BUILD_SH" ]; then
    echo "SKIP $name (no build.sh)"
    continue
  fi

  echo ""
  echo "── Build: $name ($dir) ──"

  if bash "$BUILD_SH" docker; then
    echo "OK $name"
    OK=$((OK + 1))

    # Make package public
    pkg_name=$(echo "$image" | awk -F/ '{print $NF}')
    if [ -n "$pkg_name" ] && command -v gh >/dev/null 2>&1; then
      gh api --method PUT "/user/packages/container/${pkg_name}/visibility" -f visibility=public 2>/dev/null || true
    fi
  else
    echo "FAIL $name (exit $?)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "═══════════════════════════════════════════════"
echo "GHCR: $OK ok, $FAIL failed"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
