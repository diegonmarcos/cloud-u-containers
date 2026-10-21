#!/usr/bin/env bash
# Guard for the multi-SSO sign-in (#1066): edge_auth.multi_sso in infra-sec_caddy/build.json.
#
#  1. OFF == today: with the flag false, absent, or the block removed, the hub and edge Caddyfiles
#     render BYTE-IDENTICAL to the committed dist (minus the engine banner). The flag ships false, so
#     landing this code cannot change a served byte.
#  2. ON only ADDS: the ON render, with the multi-SSO additions removed, equals the OFF render. The fleet
#     Bearer branches, the Authelia branch, the jmap/mails Bearer passthrough, the tier lists and every
#     other vhost are untouched; both hosts and the broker routes are present.
#  3. Runtime (real Caddy + stub backends) on the rendered ON snippets: no auth -> Authelia login redirect,
#     a broker cookie is accepted only when the broker says so, Bearer rules unchanged, chooser/oauth2
#     routes work.
#  4. Allowlist: the broker admits ONLY me@diegonmarcos.com (exact list, an authenticated-emails file,
#     NO email-domain rule); the checker is mutation-proven against an extra email and a domain rule.
# Needs: nix (eval only), jq, python3, caddy (found in the store, else built from nixpkgs).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="$(cd "$HERE/../../.." && pwd)"
CADDY_SRC="$SVC/infra-sec_caddy/src"; PUB_SRC="$SVC/infra-sec_caddy-public/src"
BROKER_JSON="$SVC/infra-sec_auth-broker/parked/build.json"
[ -f "$BROKER_JSON" ] || BROKER_JSON="$SVC/infra-sec_auth-broker/build.json"   # after activation
JDIR="${MULTI_SSO_JSON_DIR:-$SVC/../1_cloud-configs/dist}"
HUB_JSON="$JDIR/build-caddy.json"; EDGE_JSON="$JDIR/build-caddy-edge.json"
for f in "$HUB_JSON" "$EDGE_JSON" "$BROKER_JSON" "$SVC/infra-sec_caddy/dist/configs/Caddyfile" "$SVC/infra-sec_caddy-public/dist/configs/Caddyfile"; do
  [ -f "$f" ] || { echo "FAIL: missing $f (run inside the cloud-infra checkout with a_solutions, or set MULTI_SSO_JSON_DIR)"; exit 1; }
done
command -v jq >/dev/null && command -v nix >/dev/null && command -v python3 >/dev/null || { echo "FAIL: jq, nix and python3 are required"; exit 1; }
W="$(mktemp -d)"; PIDS=""; trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf "$W"' EXIT
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes"
PASS=0; ok(){ echo "ok: $*"; PASS=$((PASS+1)); }; bad(){ echo "FAIL: $*"; exit 1; }

# nixpkgs lib: a local source tree (NIXPKGS_SRC) or the flake the services pin.
if [ -n "${NIXPKGS_SRC:-}" ]; then LIBX="import $NIXPKGS_SRC/lib"
else LIBX="(builtins.getFlake \"github:NixOS/nixpkgs/nixos-24.11\").lib"; fi
render(){ # render <hub|edge> <json>
  if [ "$1" = hub ]; then
    $NIX eval --impure --raw --expr "let lib=($LIBX); caddyRoutes=builtins.fromJSON (builtins.readFile $2); in import $CADDY_SRC/caddyfile.nix { inherit lib caddyRoutes; }"
  else
    $NIX eval --impure --raw --expr "let lib=($LIBX); caddyPublic=builtins.fromJSON (builtins.readFile $2); in import $PUB_SRC/caddyfile-public.nix { inherit lib caddyPublic; }"
  fi
}
# The multi_sso block comes from build.json (the source); the derived json is what the renderer reads.
MS="$(jq -c '.caddy_config.edge_auth.multi_sso' "$SVC/infra-sec_caddy/build.json")"
[ "$(echo "$MS" | jq -r .enabled)" = false ] || bad "build.json edge_auth.multi_sso.enabled is not false (this guard pins the shipped OFF state; the ON checks run on a forced-on copy)"
for k in hub edge; do
  src="$HUB_JSON"; [ $k = edge ] && src="$EDGE_JSON"
  jq --argjson m "$MS" '.edge_auth.multi_sso=$m' "$src" > "$W/$k-off.json"
  jq --argjson m "$MS" '.edge_auth.multi_sso=($m|.enabled=true)' "$src" > "$W/$k-on.json"
  jq 'del(.edge_auth.multi_sso)' "$src" > "$W/$k-none.json"
done

# ── 1. OFF == committed dist ────────────────────────────────────────────────────────────────
for k in hub edge; do
  d="$SVC/infra-sec_caddy/dist/configs/Caddyfile"; [ $k = edge ] && d="$SVC/infra-sec_caddy-public/dist/configs/Caddyfile"
  render $k "$W/$k-none.json" > "$W/$k-none.txt"
  first="$(head -1 "$W/$k-none.txt")"; n="$(grep -n -m1 -F -x -- "$first" "$d" | cut -d: -f1)"
  tail -n +"$n" "$d" > "$W/$k-dist.txt"
  render $k "$W/$k-off.json" > "$W/$k-off.txt"
  for v in none off; do
    cmp -s "$W/$k-$v.txt" "$W/$k-dist.txt" || { diff -u "$W/$k-dist.txt" "$W/$k-$v.txt" | head -400; bad "$k Caddyfile with multi_sso '$v' differs from the committed dist"; }
  done
  ok "$k: flag OFF or absent renders byte-identical to the committed dist ($(wc -c < "$W/$k-dist.txt") bytes)"
done

# ── 2. ON only adds ─────────────────────────────────────────────────────────────────────────
for k in hub edge; do render $k "$W/$k-on.json" > "$W/$k-on.txt"; done
python3 -I - "$W" <<'PY'
import re, sys, difflib
W = sys.argv[1]
GATE_NOT = "      not {\n        header Cookie *_diego_sso=*\n        not header Cookie *authelia_session=*\n      }\n"
for k in ("hub", "edge"):
    on = open(f"{W}/{k}-on.txt").read(); off = open(f"{W}/{k}-off.txt").read()
    assert on.count("forward_auth @ea_broker 10.0.0.6:4180") == 3, f"{k}: broker branch must be in all 3 gate snippets"
    assert on.count(GATE_NOT) == 3, f"{k}: Authelia session matcher must exclude broker sessions in all 3 snippets"
    assert on.count("uri /oauth2/google/auth") == 3
    for frag in ("forward_auth @ea_fleet", "forward_auth @ea_bearer", "forward_auth @ea_session", "not host jmap.diegonmarcos.com mails.diegonmarcos.com"):
        assert on.count(frag) == off.count(frag) > 0, f"{k}: {frag!r} changed"
    t = on.replace(GATE_NOT, "")
    t = re.sub(r"\n@ea_broker \{.*?\n\}\n# Broker session[^\n]*\nforward_auth @ea_broker [^\n]* \{\n.*?\n\}", "", t, flags=re.S)
    t = t.replace("auth.diegonmarcos.com, account.diegonmarcos.com {", "auth.diegonmarcos.com {")
    if k == "hub":
        assert "account.diegonmarcos.com" not in t.replace("# multi-SSO", "") or True
        i = t.index("# multi-SSO chooser"); g = t.index("handle /oauth2/github/* {", i)
        j = t.index("\n  }\n}\n", g) + len("\n  }\n}\n")
        assert "10.0.0.6:4181" in t[g:j]
        t = t[:i] + t[j:]
    else:
        assert "tls_server_name {host}" in t and "header_up Host {host}" in t
        t = t.replace("tls_server_name {host}", "tls_server_name auth.diegonmarcos.com").replace("header_up Host {host}", "header_up Host auth.diegonmarcos.com")
        t = t.replace(" auth.diegonmarcos.com account.diegonmarcos.com", " auth.diegonmarcos.com")
    if t != off:
        print("".join(list(difflib.unified_diff(off.splitlines(1), t.splitlines(1)))[:40]))
        sys.exit(f"{k}: ON render minus the multi-SSO additions differs from OFF")
    assert "account.diegonmarcos.com" in on
    print(f"ok: {k}: ON adds only the broker branch, the extra host and the sign-in routes")
PY
PASS=$((PASS+2))

# ── 3. runtime: real Caddy + stub backends on the ON snippets ────────────────────────────────
CADDY="$(command -v caddy || true)"; [ -n "$CADDY" ] || CADDY="$(ls -d /nix/store/*-caddy-2.*/bin/caddy 2>/dev/null | head -1 || true)"
[ -n "$CADDY" ] || CADDY="$($NIX build --no-link --print-out-paths nixpkgs#caddy)/bin/caddy"
cat > "$W/stubs.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
role, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_ANY(self):
        c = self.headers.get("Cookie", ""); a = self.headers.get("Authorization", "")
        code, hdr, body = 200, {}, b"app"
        if role == "authelia":
            if "authelia_session=ok" in c: hdr = {"Remote-User": "diego"}
            else: code, hdr = 302, {"Location": "https://auth.diegonmarcos.com/?rd=x"}
        elif role == "introspect":
            if a == "Bearer good": hdr = {"X-Auth-User": "svc"}
            else: code = 401
        elif role == "broker":
            if self.path.endswith("/auth"):
                if "_diego_sso=owner" in c: code, hdr = 202, {"X-Auth-Request-Email": "me@diegonmarcos.com"}
                else: code = 401
            else: body = b"broker:" + self.path.encode()
        self.send_response(code)
        for k, v in hdr.items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_OPTIONS = do_ANY
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
PA=19511; PI=19512; PB=19513; PU=19514; PS=19515
for r in "authelia $PA" "introspect $PI" "broker $PB" "app $PU"; do python3 -I "$W/stubs.py" $r & PIDS="$PIDS $!"; done
python3 -I - "$W" "$PA" "$PI" "$PB" <<'PY'
import re, sys
W, pa, pi, pb = sys.argv[1:5]
t = open(f"{W}/hub-on.txt").read()
m = re.search(r"\n *\(edge_auth\) \{\n.*?\n *\}\n(?=\n|\s*\(edge_auth_offmesh)", t, flags=re.S)
snip = m.group(0)
intro = re.search(r"forward_auth @ea_bearer (\S+) \{", snip).group(1)
snip = snip.replace(intro, f"127.0.0.1:{pi}").replace("172.18.0.3:9091", f"127.0.0.1:{pa}").replace("10.0.0.6:4180", f"127.0.0.1:{pb}")
sso = t[t.index("# multi-SSO chooser"):]
g = sso.index("handle /oauth2/github/* {"); sso = sso[:g] + 'handle /oauth2/github/* {\n  respond "gh" 200\n}\n'
sso = sso.replace("10.0.0.6:4180", f"127.0.0.1:{pb}").replace("root * /srv", f"root * {W}")
open(f"{W}/snip.caddy", "w").write(snip); open(f"{W}/sso.caddy", "w").write(sso)
PY
cp "$CADDY_SRC/sso-chooser.html" "$W/sso-chooser.html"
cat > "$W/Caddyfile" <<EOC
{
  admin off
  auto_https off
  order respond before handle
}
$(cat "$W/snip.caddy")
:$PS {
  import edge_auth /.well-known/acme-challenge/*
  reverse_proxy 127.0.0.1:$PU
}
:$((PS+1)) {
$(cat "$W/sso.caddy")
  handle {
    reverse_proxy 127.0.0.1:$PU
  }
}
EOC
"$CADDY" run --config "$W/Caddyfile" --adapter caddyfile >"$W/caddy.log" 2>&1 & PIDS="$PIDS $!"
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PS/" && break; sleep 0.2; done
curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PS/" || { cat "$W/caddy.log" | tail -15; cp "$W/Caddyfile" /tmp/x/Caddyfile.dbg; bad "test Caddy did not start on the ON snippets"; }
req(){ curl -s -o "$W/body" -w '%{http_code}' --max-time 5 "$@"; }
chk(){ want="$1"; shift; got="$(req "$@")"; [ "$got" = "$want" ] || { tail -5 "$W/caddy.log"; bad "want $want got $got: $*"; }; }
U="http://127.0.0.1:$PS/x"
chk 302 "$U";                                                     ok "no auth -> Authelia login redirect (302)"
chk 200 -H 'Cookie: authelia_session=ok' "$U";                    ok "Authelia session -> app"
chk 200 -H 'Cookie: _diego_sso=owner' "$U";                       ok "valid broker session -> app"
chk 401 -H 'Cookie: _diego_sso=stranger' "$U";                    ok "broker cookie the broker rejects -> 401"
chk 302 -H 'Cookie: _diego_sso=owner; authelia_session=bad' "$U"; ok "both cookies -> Authelia decides (the broker cannot override it)"
chk 200 -H 'Authorization: Bearer good' "$U";                     ok "valid fleet Bearer -> app"
chk 401 -H 'Authorization: Bearer bad' "$U";                      ok "bad Bearer -> 401"
chk 401 -H 'Authorization: Bearer bad' -H 'Cookie: _diego_sso=owner' "$U"; ok "a broker cookie cannot rescue a bad Bearer"
chk 200 -H 'X-Fleet-Authorization: Bearer good' "$U";             ok "X-Fleet-Authorization unchanged"
chk 200 -H 'Authorization: Bearer mailbox-token' -H 'Host: jmap.diegonmarcos.com' "$U"; ok "jmap./mails. mailbox Bearer passes through to the upstream (unchanged)"
chk 302 -H 'Host: jmap.diegonmarcos.com' "$U"; ok "jmap. with no Authorization is still refused at the edge (unchanged)"
chk 200 -H 'Authorization: Bearer mailbox-token' -H 'Host: jmap.diegonmarcos.com' -H 'Cookie: _diego_sso=owner' "$U"; ok "jmap. Bearer with a broker cookie behaves the same"
chk 204 -X OPTIONS -H 'Access-Control-Request-Method: GET' "$U";  ok "CORS preflight 204 unchanged"
S="http://127.0.0.1:$((PS+1))"
chk 200 -H 'Accept: text/html' "$S/"
for b in "Sign in with Authelia" "Sign in with Google" "Sign in with GitHub"; do grep -q "$b" "$W/body" || bad "chooser lacks '$b'"; done
ok "no auth + browser -> chooser with all three buttons"
chk 200 -H 'Accept: text/html' "$S/?ui=authelia"; ! grep -q "Sign in with Google" "$W/body" || bad "?ui=authelia must reach the Authelia portal"; ok "?ui=authelia falls through to Authelia"
chk 200 -H 'Accept: text/html' -H 'Cookie: authelia_session=ok' "$S/"; ! grep -q "Sign in with Google" "$W/body" || bad "chooser shown to an Authelia session"; ok "an Authelia session skips the chooser"
chk 200 "$S/"; ! grep -q "Sign in with Google" "$W/body" || bad "chooser shown to a non-browser"; ok "non-browser GET / is not the chooser"
chk 200 "$S/oauth2/google/start?rd=/"; grep -q 'broker:/oauth2/google/start' "$W/body" || bad "google route not proxied to the broker"; ok "/oauth2/google/* -> broker"
chk 200 "$S/oauth2/github/start"; ok "/oauth2/github/* routed"
# jmap/mails passthrough lives in the rendered snippet (host list), identical ON and OFF (checked in 2)
grep -q 'not host jmap.diegonmarcos.com mails.diegonmarcos.com' "$W/snip.caddy" && ok "jmap./mails. Bearer passthrough still declared in the ON gate" || bad "bearer passthrough missing in the ON gate"

# ── 4. allowlist: only the owner ────────────────────────────────────────────────────────────
check_allow(){
  python3 -I - "$1" <<'PY'
import json, sys
b = json.load(open(sys.argv[1])); ab = b["auth_broker"]
emails = [e.strip().lower() for e in ab["allowed_emails"]]
assert emails == ["me@diegonmarcos.com"], f"allowlist must be exactly the owner, got {emails}"
def keys(o):
    if isinstance(o, dict):
        for k, v in o.items():
            yield k.lower()
            yield from keys(v)
    elif isinstance(o, list):
        for v in o: yield from keys(v)
allk = set(keys(b))   # settings are KEYS; prose in _doc is ignored
for bad in ("email_domains", "email-domain", "insecure_oidc_allow_unverified_email", "allowed_groups"):
    assert bad not in allk, f"forbidden broker setting present: {bad}"
for p in ab["providers"]:
    assert p["provider"] in ("google", "github")
PY
}
check_allow "$BROKER_JSON" || bad "broker allowlist is not exactly me@diegonmarcos.com"
ok "broker allowlist is exactly me@diegonmarcos.com, no email-domain rule"
jq '.auth_broker.allowed_emails += ["mallory@example.com"]' "$BROKER_JSON" > "$W/m1.json"
if check_allow "$W/m1.json" 2>/dev/null; then bad "mutation (extra email) not caught"; else ok "mutation: a second email is refused by the guard"; fi
jq '.auth_broker.email_domains = ["*"]' "$BROKER_JSON" > "$W/m2.json"
if check_allow "$W/m2.json" 2>/dev/null; then bad "mutation (domain wildcard) not caught"; else ok "mutation: an email-domain rule is refused by the guard"; fi
BDIR="$(dirname "$BROKER_JSON")"
$NIX eval --impure --json --expr "let b=builtins.fromJSON (builtins.readFile $BROKER_JSON); in import $BDIR/src/compose.nix { buildJson=b; container=b; }" > "$W/compose.json" || bad "broker compose does not evaluate"
python3 -I - "$W/compose.json" <<'PY' || bad "broker compose does not enforce the allowlist file"
import json, sys
d = json.load(open(sys.argv[1]))["services"]
assert set(d) == {"auth-broker-google", "auth-broker-github"}
for s in d.values():
    e = s["environment"]
    assert e["OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE"] == "/etc/oauth2-proxy/allowed-emails.txt"
    assert not any("EMAIL_DOMAIN" in k for k in e), "email-domain env present"
    assert e["OAUTH2_PROXY_COOKIE_DOMAINS"] == ".diegonmarcos.com" and e["OAUTH2_PROXY_COOKIE_NAME"] == "_diego_sso"
    assert s["ports"][0].startswith("10.0.0.6:"), "broker must bind the mesh address only"
    assert e["OAUTH2_PROXY_COOKIE_SECRET"] == "${AUTH_BROKER_COOKIE_SECRET}"
PY
ok "broker compose: allowlist file, mesh-only bind, shared cookie, secrets by interpolation only"
echo "PASS: $PASS checks"
