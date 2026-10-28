#!/usr/bin/env bash
# Guard for true SSO (#1147): per-service Authelia OIDC clients, header-auth identity rows, and the
# rule that no secret value is ever committed to this public repo.
#  1. The seven service clients exist with the EXACT redirect URIs (no wildcard, https only), a
#     unique secret_var, no inline secret, and are disabled-or-enabled explicitly.
#  2. The flake renders only clients that are not disabled (so a missing secret file cannot stop Authelia).
#  3. Every service compose gates its OIDC env on <SVC>_OIDC_CLIENT_SECRET (inert when unset).
#  4. Header-auth: filebrowser (the only consumer) declares proxy.primary.identity with mapped rows only; services that do not read the header declare none.
#  5. No client_secret literal / password hash / private key in the Authelia sources.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; SVC="$(cd "$HERE/../../.." && pwd)"
FAIL=0; ok(){ echo "ok   $*"; }; bad(){ echo "FAIL $*" >&2; FAIL=1; }
CL="$SVC/infra-sec_authelia/src/oidc-clients.json"
python3 - "$CL" <<'PY' || FAIL=1
import json, sys
exp = {
 "gitea": "https://git.@BASE_DOMAIN@/user/oauth2/authelia/callback",
 "hedgedoc": "https://app.@BASE_DOMAIN@/hedgedoc/auth/oauth2/callback",
 "grist": "https://sheets.@BASE_DOMAIN@/oauth2/callback",
 "photoprism": "https://photos.@BASE_DOMAIN@/api/v1/oidc/redirect",
 "dagu-ui": "https://workflows.@BASE_DOMAIN@/oidc-callback",
 "dbgate": "https://db.@BASE_DOMAIN@/",
 "etherpad": "https://app.@BASE_DOMAIN@/etherpad/ep_openid_connect/callback",
}
cs = json.load(open(sys.argv[1]))["clients"]
ids = [c["client_id"] for c in cs]; vars_ = [c["secret_var"] for c in cs]
bad = 0
def f(m):
    global bad; bad = 1; print("FAIL " + m, file=sys.stderr)
if len(set(ids)) != len(ids): f("duplicate client_id")
if len(set(vars_)) != len(vars_): f("duplicate secret_var")
for cid, uri in exp.items():
    c = next((c for c in cs if c["client_id"] == cid), None)
    if not c: f("client %s not declared" % cid); continue
    if c.get("redirect_uris") != [uri]: f("%s redirect_uris %r != exact %r" % (cid, c.get("redirect_uris"), [uri]))
    if "*" in uri or not uri.startswith("https://"): f("%s redirect not exact https" % cid)
    if c.get("public") is not False: f("%s must be a confidential client" % cid)
    if c.get("authorization_policy") != "two_factor": f("%s must require two_factor" % cid)
    if "client_secret" in c: f("%s carries an inline client_secret" % cid)
    if not c["secret_var"].startswith("AUTHELIA_OIDC_CLIENT_") or not c["secret_var"].endswith("_SECRET"): f("%s secret_var naming" % cid)
    if not isinstance(c.get("enabled", True), bool): f("%s enabled must be boolean" % cid)
    if c.get("grant_types") != ["authorization_code"]: f("%s grant_types" % cid)
    print("ok   client %s %s" % (cid, "enabled" if c.get("enabled", True) else "declared, disabled until its secret is delivered"))
sys.exit(bad)
PY
grep -q 'builtins.filter (c: (c.enabled or true))' "$SVC/infra-sec_authelia/src/flake.nix" \
  && ok "flake renders only clients not disabled" || bad "flake does not filter disabled clients"
# 3. compose gating
chk(){ f="$SVC/$1/src/compose.nix"; v="$2"
  if grep -q "\${$v:" "$f" && ! grep -Eq "OIDC.*(SECRET|secret).*= *\"[A-Za-z0-9+/=_-]{16,}\"" "$f"; then ok "$1 gates OIDC on $v"; else bad "$1 OIDC not gated on $v"; fi; }
chk user-prod_hedgedoc HEDGEDOC_OIDC_CLIENT_SECRET
chk user-prod_grist GRIST_OIDC_CLIENT_SECRET
chk user-media_photoprism PHOTOPRISM_OIDC_CLIENT_SECRET
chk infra-obs_dagu DAGU_OIDC_CLIENT_SECRET
chk infra-obs_dbgate DBGATE_OIDC_CLIENT_SECRET
chk user-prod_etherpad ETHERPAD_OIDC_CLIENT_SECRET
# dagu has no "oidc" auth mode (OIDC lives under builtin); the default must stay none
grep -q 'DAGU_AUTH_MODE=\\${DAGU_AUTH_MODE:-none}' "$SVC/infra-obs_dagu/src/compose.nix" && ! grep -q 'DAGU_AUTH_MODE=oidc' "$SVC/infra-obs_dagu/src/compose.nix" \
  && ok "dagu auth mode defaults to none, never the non-existent oidc mode" || bad "dagu auth mode wiring"
# dbgate's OAuth provider posts the secret in the body: the Authelia client must use client_secret_post
python3 -c "
import json,sys
c={x['client_id']:x for x in json.load(open('$CL'))['clients']}
sys.exit(0 if c['dbgate']['token_endpoint_auth_method']=='client_secret_post' else 1)" && ok "dbgate client uses client_secret_post" || bad "dbgate client auth method"
grep -q 'GITEA_OIDC_CLIENT_SECRET:-' "$SVC/infra-dat_gitea/src/templates/init-mirrors.sh.tpl" \
  && ok "gitea source converge is gated on GITEA_OIDC_CLIENT_SECRET" || bad "gitea sso block not gated"
# 4. identity rows
for s in user-prod_filebrowser; do
  python3 - "$SVC/$s/build.json" "$s" <<'PY' || FAIL=1
import json, sys
d = json.load(open(sys.argv[1])); i = d["proxy"]["primary"].get("identity"); n = sys.argv[2]
def f(m): print("FAIL %s identity: %s" % (n, m), file=sys.stderr); sys.exit(1)
if not i: f("missing")
if not i.get("header"): f("no header")
rows = {**i.get("session", {}), **i.get("bearer", {})}
if i.get("session", {}).get("me@diegonmarcos.com", "") in ("", "-"): f("no session row for the owner")
for k, v in rows.items():
    if k == "default" or k.startswith("~") or v in ("", "-"): f("row %r -> %r maps an unmapped identity" % (k, v))
print("ok   %s header auth via %s" % (n, i["header"]))
PY
done
# Services whose app does NOT consume the header must not declare identity: the edge answers 403 to every
# validated identity without a row, so an unused identity block only locks out bearer clients. notes-web has no
# login (static, the gate is the auth), radicale stays on Stalwart IMAP auth, playlist-syncer (Spotube) has no
# header support. Add the block back in the same commit that makes the app read the header.
for s in user-prod_calendar-radicale user-prod_contacts-radicale user-prod_cloud-notes-web user-media_playlist-syncer; do
  python3 -c "
import json,sys
d=json.load(open('$SVC/$s/build.json'))
sys.exit(1 if 'identity' in d['proxy']['primary'] else 0)" && ok "$s declares no unused identity (app does not read the header)" || bad "$s declares identity but its app does not read the header"
done
# 5. no secret material
bad_hits="$(grep -rEn '(client_secret: *.?\$pbkdf2|\$pbkdf2-sha512|BEGIN (RSA |EC )?PRIVATE KEY)' "$SVC/infra-sec_authelia/src" --include=*.json --include=*.nix --include=*.sh --include=*.tpl 2>/dev/null | grep -v 'src/test/test-sso-oidc.sh' || true)"
[ -z "$bad_hits" ] && ok "no secret material in the Authelia sources" || bad "secret material: $bad_hits"
exit "$FAIL"
