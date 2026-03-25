#!/usr/bin/env bash
# ── Check all public HTTP endpoints ──
# Usage: health-http-public.sh
# Reads caddy-routes.json, curls every public domain
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

R="cloud-data/cloud-data-caddy-routes.json"
[ ! -f "$R" ] && echo "ERROR: $R not found" >&2 && exit 1

URLS="/tmp/urls-$$.txt"
> "$URLS"

# Subdomain routes
jq -r '.routes[] | select(.domain) | "https://\(.domain)/|\(.auth // "two_factor")|\(.comment // .domain)"' "$R" >> "$URLS" 2>/dev/null
# Path routes
jq -r '.path_routes[]? | .parent_domain as $p | .paths[]? | select(.upstream) | "https://\($p)\(.base_path)/|\(.auth // "two_factor")|\(.comment // .base_path)"' "$R" >> "$URLS" 2>/dev/null
# GitHub Pages
jq -r '.github_pages_proxies[]? | "https://\(.domain | split(",") | .[0] | gsub("^ +| +$";""))/|none|\(.comment // .domain)"' "$R" >> "$URLS" 2>/dev/null
# MCP endpoints
jq -r '.mcp_routes[]? | .parent_domain as $p | .endpoints[]? | "https://\($p)\(.base_path)/mcp|mcp|\(.base_path)"' "$R" >> "$URLS" 2>/dev/null

TOTAL=$(wc -l < "$URLS")
echo "Checking $TOTAL public URLs..."

RESULTS="/tmp/results-$$"
mkdir -p "$RESULTS"

BEARER="${OIDC_TOKEN:-${AUTHELIA_BEARER_TOKEN:-}}"

check_url() {
  local idx="$1" url="$2" auth="$3" name="$4"
  local hdr=""
  [ "$auth" != "none" ] && [ "$auth" != "mcp" ] && [ -n "$BEARER" ] && hdr="-H 'Authorization: Bearer $BEARER'"
  local code
  code=$(eval curl -sk -o /dev/null -w '%{http_code}' --max-time 10 $hdr "'$url'" 2>/dev/null)

  if [ "$auth" = "mcp" ] && { [ "$code" = "400" ] || [ "$code" = "405" ]; }; then
    echo "PASS|$name|$code" > "$RESULTS/$idx"
  elif [ "$code" = "000" ] || [ "$code" = "502" ] || [ "$code" = "503" ]; then
    echo "FAIL|$name|$code" > "$RESULTS/$idx"
  else
    echo "PASS|$name|$code" > "$RESULTS/$idx"
  fi
}

IDX=0
while IFS='|' read -r url auth name; do
  check_url "$IDX" "$url" "$auth" "$name" &
  IDX=$((IDX + 1))
done < "$URLS"
wait

PASS_N=0; FAIL_N=0
for f in "$RESULTS"/*; do
  [ -f "$f" ] || continue
  LINE=$(cat "$f")
  STATUS=${LINE%%|*}
  REST=${LINE#*|}
  case "$STATUS" in
    PASS) echo "✓ $REST"; PASS_N=$((PASS_N + 1)) ;;
    FAIL) echo "✗ $REST"; FAIL_N=$((FAIL_N + 1)) ;;
  esac
done

rm -rf "$URLS" "$RESULTS"
echo ""
echo "RESULT: $PASS_N passed, $FAIL_N failed (of $TOTAL)"
[ "$FAIL_N" -gt 0 ] && exit 1
exit 0
