#!/usr/bin/env bash
# ── Check all .app DNS resolution (private mesh) ──
# Usage: cloud-health-http-private.sh
# Resolves all .app names via hickory-dns on gcp-proxy
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# 2026-04-27 migrated: cloud-data-dns-services.json -> _cloud-data-consolidated.json[.services,.vms]
CONS=""
for p in "2_configs/dist/_cloud-data-consolidated.json" \
         "/var/lib/dagu/data/cloud-data/_cloud-data-consolidated.json" \
         "/var/lib/dagu/data/cloud-data/2_configs/dist/_cloud-data-consolidated.json" \
         "/app/_cloud-data-consolidated.json"; do
  [ -f "$p" ] && CONS="$p" && break
done
DNS_FILE=""
if [ -n "$CONS" ]; then
  DNS_FILE="${RUNNER_TEMP:-/tmp}/derived-dns-services.$$.json"
  jq '
    (.vms | to_entries[] | select(.value.ssh_alias == "gcp-proxy") | .value.wg_ip) as $caddy_ip
    | {
        caddy_ip: $caddy_ip,
        services: (
          [
            (.services | to_entries[] | {key: .key, value: {ip: $caddy_ip}}),
            (.services | to_entries[] | .value.containers // {} | to_entries[]
              | select(.value.dns)
              | {key: (.value.dns | split(".")[0]), value: {ip: $caddy_ip}})
          ] | from_entries
        )
      }
  ' "$CONS" > "$DNS_FILE"
else
  for p in "2_configs/dist/cloud-data-dns-services.json" \
           "/var/lib/dagu/data/cloud-data/cloud-data-dns-services.json" \
           "/var/lib/dagu/data/cloud-data/2_configs/dist/cloud-data-dns-services.json" \
           "/app/cloud-data-dns-services.json"; do
    [ -f "$p" ] && DNS_FILE="$p" && break
  done
fi
[ -z "$DNS_FILE" ] && echo "ERROR: _cloud-data-consolidated.json (or legacy cloud-data-dns-services.json) not found in any known location" >&2 && exit 1

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
