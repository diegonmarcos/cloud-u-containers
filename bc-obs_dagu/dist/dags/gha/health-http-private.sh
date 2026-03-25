#!/usr/bin/env bash
# ── Check all .app DNS resolution (private mesh) ──
# Usage: health-http-private.sh
# Resolves all .app names via hickory-dns on gcp-proxy
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

DNS_FILE="cloud-data/cloud-data-dns-services.json"
[ ! -f "$DNS_FILE" ] && echo "ERROR: $DNS_FILE not found" >&2 && exit 1

NAMES=$(jq -r '.services | keys[]' "$DNS_FILE" | sort)
TOTAL=$(echo "$NAMES" | wc -w)
echo "Resolving $TOTAL .app names..."

# Build batch dig script for single SSH call
SCRIPT=""
for name in $NAMES; do
  SCRIPT="$SCRIPT echo \"==$name==\"; dig +short ${name}.app @10.0.0.1 2>/dev/null | head -1;"
done

BATCH_RESULT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 gcp-proxy "$SCRIPT" 2>/dev/null) || {
  echo "ERROR: SSH to gcp-proxy failed"
  exit 1
}

PASS_N=0; FAIL_N=0; WARN_N=0
CURRENT_NAME=""

echo "$BATCH_RESULT" | while read -r line; do
  if echo "$line" | command grep -q "^==.*==$"; then
    CURRENT_NAME=$(echo "$line" | awk -F'==' '{print $2}')
  elif [ -n "$CURRENT_NAME" ]; then
    RESOLVED="$line"
    EXPECTED=$(jq -r ".services[\"$CURRENT_NAME\"].ip // \"\"" "$DNS_FILE")
    if [ -z "$RESOLVED" ]; then
      echo "⚠ ${CURRENT_NAME}.app → no zone"
      WARN_N=$((WARN_N + 1))
    elif [ "$RESOLVED" = "$EXPECTED" ]; then
      echo "✓ ${CURRENT_NAME}.app → $RESOLVED"
      PASS_N=$((PASS_N + 1))
    else
      echo "✗ ${CURRENT_NAME}.app → expected=$EXPECTED got=$RESOLVED"
      FAIL_N=$((FAIL_N + 1))
    fi
    CURRENT_NAME=""
  fi
done

echo ""
echo "RESULT: $PASS_N passed, $FAIL_N failed, $WARN_N warnings"
[ "$FAIL_N" -gt 0 ] && exit 1
exit 0
