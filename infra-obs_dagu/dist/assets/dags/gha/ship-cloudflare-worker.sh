#!/usr/bin/env bash
# ── Deploy Cloudflare Worker ──
# Usage: ship-cloudflare-worker.sh
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

echo "── Ship cloudflare-worker ──"
bash a_solutions/ba-clo_cloudflare-worker/build.sh ship
