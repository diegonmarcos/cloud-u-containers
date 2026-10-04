#!/usr/bin/env bash
# Tester: every deploy leaves config.yaml and registration.yaml on the sops
# token pair. registration.yaml is what the homeserver registers at startup
# (matrix-continuwuity admin_execute); config.yaml is what the bridge presents.
# If a redeploy after a rotation refreshes one and not the other, the bridge
# dies with "as_token was not accepted" — the outage this guards.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
check() { if "${@:2}"; then echo "  ok   $1"; else echo "  FAIL $1"; FAILED=$((FAILED + 1)); fi; }

mkdir -p "$WORK/assets" "$WORK/configs" "$WORK/data"
cp "$HERE/assets/compose-pre-hook.sh" "$WORK/assets/"
for t in config registration; do sed 's/@[A-Z_]*@/x/g' "$HERE/templates/$t.yaml.tpl" > "$WORK/configs/$t.yaml"; done
deploy() { printf 'AS_TOKEN=%s\nHS_TOKEN=%s\n' "$1" "$2" > "$WORK/.secrets"; sh "$WORK/assets/compose-pre-hook.sh"; }
tokens() { grep -E '^[[:space:]]*(as|hs)_token:' "$WORK/data/$1" | sed 's/^[[:space:]]*//' | tr '\n' ' '; }
want() { echo "as_token: \"$1\" hs_token: \"$2\" "; }

echo "-- first deploy seeds both files"
deploy old1 old2
check "registration.yaml carries the pair" test "$(tokens registration.yaml)" = "$(want old1 old2)"
check "config.yaml carries the pair" test "$(tokens config.yaml)" = "$(want old1 old2)"

echo "-- the bridge rewrites its config; then the pair is rotated and redeployed"
echo "bridge_owned_setting: keep-me" >> "$WORK/data/config.yaml"
deploy new1 new2
check "registration.yaml follows the rotation" test "$(tokens registration.yaml)" = "$(want new1 new2)"
check "config.yaml follows the rotation" test "$(tokens config.yaml)" = "$(want new1 new2)"
check "the bridge's own config edits survive" grep -qx "bridge_owned_setting: keep-me" "$WORK/data/config.yaml"

[ "$FAILED" -eq 0 ] || { echo "FAIL: $FAILED assertion(s)"; exit 1; }
echo "PASS: config.yaml and registration.yaml stay on one sops token pair across redeploys"
