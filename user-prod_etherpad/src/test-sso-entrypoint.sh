#!/usr/bin/env bash
# Tester (#1147): configs/sso-entrypoint.sh is INERT without the client secret and wires ep_openid_connect with it.
#  G1 secret unset -> no pnpm call, settings.json untouched, REQUIRE_AUTHENTICATION not exported, exec == upstream CMD
#  G2 secret set   -> plugin installed, one ep_openid_connect block after the opening brace, REQUIRE_AUTHENTICATION=true
#  G3 secret never written to disk (settings holds the ${...} placeholder only)
#  G4 second run does not duplicate the block
#  G5 plugin install failure -> still starts (no SSO), exit path reaches exec
#  G6 compose overrides CMD with exactly this script and the exec line equals the upstream CMD
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; TPL="$HERE/templates/sso-entrypoint.sh.tpl"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAIL=0; ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*" >&2; FAIL=1; }
mkdir -p "$W/bin" "$W/ep/src"
cat > "$W/bin/pnpm" <<'S'
#!/bin/sh
echo "$@" >> "$STUB_LOG"; [ "${STUB_PNPM_FAIL:-0}" = 1 ] && exit 1; exit 0
S
cat > "$W/bin/node" <<'S'
#!/bin/sh
echo "node $* REQ=${REQUIRE_AUTHENTICATION:-unset}" >> "$STUB_LOG"
S
chmod +x "$W/bin/pnpm" "$W/bin/node"
fresh(){ printf '/* comment */\n{\n  "title": "Etherpad",\n  "requireAuthentication": "${REQUIRE_AUTHENTICATION:false}"\n}\n' > "$W/ep/settings.json"; : > "$W/log"; }
run(){ ( cd "$W" && env -i PATH="$W/bin:/usr/bin:/bin" EP_DIR="$W/ep" TMPDIR="$W" STUB_LOG="$W/log" "$@" sh "$TPL" ) >/dev/null 2>&1; }
fresh; run
grep -q pnpm "$W/log" && bad "G1 pnpm ran without the secret" || ok "G1 no plugin install without the secret"
cmp -s "$W/ep/settings.json" <(printf '/* comment */\n{\n  "title": "Etherpad",\n  "requireAuthentication": "${REQUIRE_AUTHENTICATION:false}"\n}\n') && ok "G1 settings.json untouched" || bad "G1 settings.json changed"
grep -q 'node --require tsx/cjs node/server.ts REQ=unset' "$W/log" && ok "G1 execs the upstream CMD, auth flag unset" || bad "G1 exec line"
fresh; run ETHERPAD_OIDC_CLIENT_SECRET=s3cr3t-value-123
grep -q 'plugins i ep_openid_connect' "$W/log" && ok "G2 installs ep_openid_connect" || bad "G2 no plugin install"
[ "$(grep -c '"ep_openid_connect"' "$W/ep/settings.json")" = 1 ] && ok "G2 one settings block" || bad "G2 block count"
awk 'NR==3 && /ep_openid_connect/ {f=1} END{exit !f}' "$W/ep/settings.json" && ok "G2 block sits right after the opening brace" || bad "G2 block position"
grep -q 'REQ=true' "$W/log" && ok "G2 requireAuthentication exported" || bad "G2 REQUIRE_AUTHENTICATION"
grep -q '"client_id": "etherpad"' "$W/ep/settings.json" && grep -q 'sso.diegonmarcos.com' "$W/ep/settings.json" && ok "G2 client id and issuer" || bad "G2 client id/issuer"
grep -rq 's3cr3t-value-123' "$W/ep" "$W"/ep-* 2>/dev/null && bad "G3 secret on disk" || ok "G3 secret not written to disk"
grep -q '\${ETHERPAD_OIDC_CLIENT_SECRET}' "$W/ep/settings.json" && ok "G3 placeholder only" || bad "G3 placeholder missing"
run ETHERPAD_OIDC_CLIENT_SECRET=s3cr3t-value-123
[ "$(grep -c '"ep_openid_connect"' "$W/ep/settings.json")" = 1 ] && ok "G4 idempotent" || bad "G4 duplicated block"
fresh; run ETHERPAD_OIDC_CLIENT_SECRET=x STUB_PNPM_FAIL=1
grep -q 'REQ=unset' "$W/log" && ! grep -q '"ep_openid_connect"' "$W/ep/settings.json" && ok "G5 install failure starts without SSO" || bad "G5 install failure path"
grep -q 'command = \[ "sh" "/sso-entrypoint.sh" \]' "$HERE/compose.nix" && grep -q 'configs/sso-entrypoint.sh:/sso-entrypoint.sh:ro' "$HERE/compose.nix" && ok "G6 compose runs the wrapper" || bad "G6 compose wiring"
tail -1 "$TPL" | grep -qx 'exec node --require tsx/cjs node/server.ts' && ok "G6 exec line matches upstream CMD" || bad "G6 exec line"
exit "$FAIL"
