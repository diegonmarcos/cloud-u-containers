#!/usr/bin/env bash
# Guard (#1104/#1102): the country set of the Cloudflare WAF rule for c3-pub equals the geo-fence declaration.
# Source of truth: _shared/geo-fence.json allowed_countries. The rule's copy lives in cloud-infra
# c_vps/ba-clo_cloudflare/src/geo-allowed.json (used by waf-c3-pub.tf). WAF_GEO_FILE overrides the fetch
# (local runs); otherwise the file is read from cloud-infra main with GH_TOKEN. No token and no file = FAIL.
# Mutation proof: a list with one country removed and one added must both be rejected.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../geo-fence.json"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
if [ -n "${WAF_GEO_FILE:-}" ]; then cp "$WAF_GEO_FILE" "$W/waf.json"
else
  [ -n "${GH_TOKEN:-}" ] || { echo "FAIL: GH_TOKEN (cloud-infra read) or WAF_GEO_FILE is required"; exit 1; }
  gh api -H "Accept: application/vnd.github.raw" repos/diegonmarcos/cloud-infra/contents/c_vps/ba-clo_cloudflare/src/geo-allowed.json >"$W/waf.json"
fi
set_of() { jq -r '.allowed_countries[]' "$1" | sort -u; }
set_of "$SRC" >"$W/want"; set_of "$W/waf.json" >"$W/got"
[ -s "$W/want" ] || { echo "FAIL: empty source set"; exit 1; }
if ! diff -u "$W/want" "$W/got" >"$W/d"; then echo "FAIL: c3-pub WAF country set differs from geo-fence.json"; cat "$W/d"; exit 1; fi
echo "ok: c3-pub WAF country set equals geo-fence.json ($(wc -l <"$W/want") countries)"
# mutation proof
for m in drop add; do
  if [ $m = drop ]; then sed '1d' "$W/got" >"$W/mut"; else { cat "$W/got"; echo ZZ; } | sort -u >"$W/mut"; fi
  if diff -q "$W/want" "$W/mut" >/dev/null; then echo "FAIL: mutation '$m' not caught"; exit 1; fi
done
echo "ok: mutations (drop, add) are caught"
