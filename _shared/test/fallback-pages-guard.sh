#!/usr/bin/env bash
# Guard: the Pages fallback input is current, public-safe, and the shared Caddy handler redirects HTML 401/403 only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
node "$ROOT/_shared/gen-fallback-services.mjs" --check
F="$ROOT/_shared/fallback-services.json"
# every build.json service has an entry
for d in "$ROOT"/*/build.json; do
  n=$(jq -r '.name // empty' "$d"); [ -z "$n" ] || jq -e --arg n "$n" '.services[]|select(.slug==$n)' "$F" >/dev/null || { echo "FAIL: $n missing from fallback-services.json"; exit 1; }
done
# no secrets / internal addresses in the published data
if grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|fd0c:|ghp_|github_pat_|sk-[A-Za-z0-9]{10}|BEGIN [A-Z ]*PRIVATE|eyJ[A-Za-z0-9_-]{20}|AKIA[0-9A-Z]{12}' "$F"; then echo "FAIL: fallback-services.json carries a secret-like or internal-address string"; exit 1; fi
bash "$ROOT/infra-sec_caddy/src/test/test-fallback-redirect.sh"
echo "ok: fallback pages guard"
