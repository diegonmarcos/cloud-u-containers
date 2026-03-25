#!/usr/bin/env bash
# ── Full cloud health diagnostic ──
# Usage: health-cloud-full.sh
# Runs health_cloud.ts inside c3-infra-mcp container (or locally with tsx)
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Try running inside the MCP container on oci-apps (has all deps + SSH keys)
RESULT=$($SSH ubuntu@10.0.0.6 "docker exec c3-infra-mcp-api npx tsx mcp/tools/health_cloud.ts 2>&1" 2>/dev/null) || true

# Fallback: run locally if tsx is available
if [ -z "$RESULT" ] && command -v tsx >/dev/null 2>&1; then
  RESULT=$(cd "$REPO_ROOT/a_solutions/bc-obs_c3-infra-mcp/src" && tsx mcp/tools/health_cloud.ts 2>&1) || true
fi

if [ -z "$RESULT" ]; then
  echo "ERROR: health_cloud.ts returned empty output"
  exit 1
fi

echo "$RESULT"

# Check for failures
FAILS=$(echo "$RESULT" | grep -c '✗' || echo 0)
[ "$FAILS" -gt 0 ] && exit 1
exit 0
