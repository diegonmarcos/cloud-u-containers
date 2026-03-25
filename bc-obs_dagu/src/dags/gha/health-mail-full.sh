#!/usr/bin/env bash
# ── Full mail health diagnostic ──
# Usage: health-mail-full.sh
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT/a_solutions/bc-obs_c3-infra-mcp/src"

# Install deps if needed (GHA already has them, Dagu/CLI may not)
[ -d node_modules ] || npm install --no-audit --no-fund 2>/dev/null || true

tsx mcp/tools/health_mail.ts
