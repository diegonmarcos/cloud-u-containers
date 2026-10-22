#!/usr/bin/env bash
# Guard for ticket #1102 (geo-fence): the public edge serves only the countries declared in
# _shared/geo-fence.json, mesh sources and declared-global hosts are exempt, and the render
# stays inside the edge container's memory limit.
#
# Static checks   : JSON shape, allow-list sanity, Dockerfile pins == JSON pins, render shape
#                   (every fenced site imports geo_fence, global hosts do not, no trusted-proxy
#                   override in the production config).
# Behaviour checks: a real Caddy (built with the same plugins as the image) loads the rendered
#                   edge Caddyfile (validate), then a throwaway instance built from the rendered
#                   (geo_fence) + handle_errors text answers requests whose client IP is forced
#                   through X-Forwarded-For (test instance only; the production config has no
#                   trusted proxies, which a static check asserts).
# Mutation proofs : an allow-list without US must deny a US address; removing `order error first`
#                   must be caught by the static check.
# Env: CADDY (caddy built with the image plugins), GEO_DB_FILE (the pinned .mmdb),
#      EDGE_JSON (build-caddy-edge.json) or EDGE_CADDYFILE (an already rendered Caddyfile).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
J="$ROOT/_shared/geo-fence.json"
SRC="$ROOT/infra-sec_caddy-public/src"
W="$(mktemp -d)"; trap 'kill $(cat "$W/pid" 2>/dev/null) 2>/dev/null || true; rm -rf "$W"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
command -v jq >/dev/null && command -v python3 >/dev/null || fail "jq and python3 are required"

# 1. declaration sanity
python3 - "$J" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
a = d["allowed_countries"]
assert all(re.fullmatch(r"[A-Z]{2}", c) for c in a), "country codes must be ISO alpha-2 upper case"
assert len(a) == len(set(a)), "duplicate country"
for c in "US GB CH DE FR ES IT NL SE NO PL UA".split():
    assert c in a, c + " must be allowed"
for c in "RU BY CN KP IR TR GE AM AZ".split():
    assert c not in a, c + " must not be allowed"
assert re.fullmatch(r"[0-9a-f]{64}", d["db"]["sha256"]), "db.sha256"
assert d["db"]["url"].startswith("https://"), "db.url"
for c in ("10.0.0.0/24", "10.1.0.0/24", "127.0.0.0/8"):
    assert c in d["exempt_cidrs"], c + " must be exempt"
for h in ("auth.diegonmarcos.com", "account.diegonmarcos.com", "mcp.diegonmarcos.com", "www.diegonmarcos.com", "diegonmarcos.com"):
    assert h not in d["global_hosts"], h + " must be fenced"
PY
ok "declaration is well formed"

# 2. Dockerfile pins equal the declaration
URL="$(jq -r .db.url "$J")"; SHA="$(jq -r .db.sha256 "$J")"; MOD="$(jq -r .db.module "$J")"
DF="$SRC/code/Dockerfile"
grep -qF "ARG GEOIP_URL=$URL" "$DF" || fail "Dockerfile GEOIP_URL differs from geo-fence.json db.url"
grep -qF "ARG GEOIP_SHA256=$SHA" "$DF" || fail "Dockerfile GEOIP_SHA256 differs from geo-fence.json db.sha256"
grep -qF -- "--with $MOD" "$DF" || fail "Dockerfile does not build the module $MOD"
grep -q 'sha256sum -c' "$DF" || fail "Dockerfile does not verify the database checksum"
ok "Dockerfile pins equal the declaration"

# 3. render the edge Caddyfile
if [ -n "${EDGE_CADDYFILE:-}" ]; then cp "$EDGE_CADDYFILE" "$W/Caddyfile"; else
  : "${EDGE_JSON:?set EDGE_JSON or EDGE_CADDYFILE}"
  nix --extra-experimental-features 'nix-command flakes' eval --impure --raw --expr \
    "let lib=((builtins.getFlake \"github:NixOS/nixpkgs/nixos-24.11\").lib); caddyPublic=builtins.fromJSON (builtins.readFile $EDGE_JSON); in import $SRC/caddyfile-public.nix { inherit lib caddyPublic; }" > "$W/Caddyfile"
fi
[ -s "$W/Caddyfile" ] || fail "empty render"

# 4. render shape
python3 - "$W/Caddyfile" "$J" <<'PY' || exit 1
import json, re, sys
t = open(sys.argv[1]).read(); d = json.load(open(sys.argv[2]))
def fail(m): print("FAIL: " + m); sys.exit(1)
gm = re.search(r"\(geo_fence\) \{.*?\n  \}", t, re.S)
if not gm or "client_ip" not in gm.group(0) or "remote_ip" in gm.group(0): fail("geo_fence must exempt by client_ip (the address the country matcher uses), not remote_ip")
if not re.search(r"^\s*order error first$", t, re.M): fail("globals lack `order error first` (geo check would run after forward_auth)")
if "(geo_fence) {" not in t: fail("no (geo_fence) snippet")
if re.search(r"trusted_proxies|client_ip_headers", t): fail("production config must not trust forwarded client IPs")
want = " ".join(d["allowed_countries"])
if ("allow_countries " + want) not in t: fail("rendered allow list differs from geo-fence.json")
if "db_path " + d["db"]["file"] not in t: fail("rendered db_path differs from geo-fence.json")
sites = re.findall(r"^(\S[^\n{]*[^\s{]) \{\n(.*?)^\}$", t, re.M | re.S)
sites = [(a, b) for a, b in sites if re.fullmatch(r"[a-z0-9.*-]+(, [a-z0-9.*-]+)*", a) and "." in a]
if len(sites) < 8: fail("found only %d site blocks, parser is wrong" % len(sites))
fenced = []
for addr, body in sites:
    names = [n.strip() for n in addr.split(",")]
    allglobal = all(n in d["global_hosts"] for n in names)
    has = "import geo_fence" in body
    if allglobal and has: fail(addr + " is declared global but imports geo_fence")
    if not allglobal and not has: fail(addr + " is not declared global but lacks geo_fence")
    if not allglobal: fenced.append(addr)
for e in d["edge_terminated"]:
    h = e["host"]
    if not re.search(r"@public tls sni [^\n]*\b" + re.escape(h) + r"\b", t): fail(h + " is edge-terminated but missing from the layer4 @public SNI list")
    if h in d["global_hosts"]: fail(h + " cannot be both edge-terminated (fenced) and global")
for h in ("auth.diegonmarcos.com", "mcp.diegonmarcos.com", "c3-pvt.diegonmarcos.com"):
    if not any(h in a for a in fenced): fail(h + " is not fenced")
print("ok: %d sites, fenced: %s" % (len(sites), "; ".join(fenced)))
PY

# 5-8 need a Caddy with the image plugins and the pinned database
if [ -z "${CADDY:-}" ] || [ -z "${GEO_DB_FILE:-}" ]; then echo "SKIP: behaviour checks (CADDY / GEO_DB_FILE not set)"; echo "ok: geo-fence static guard"; exit 0; fi
[ "$(sha256sum "$GEO_DB_FILE" | cut -d' ' -f1)" != "" ] || fail "database unreadable"
"$CADDY" list-modules | grep -q 'http.matchers.maxmind_geolocation' || fail "CADDY lacks the geolocation module"

# 5. the full rendered edge config loads with the real modules, and stays small
mkdir -p "$W/log" "$W/xdg"
sed -e "s#/var/log/caddy#$W/log#g" -e "s#db_path [^ ]*#db_path $GEO_DB_FILE#" "$W/Caddyfile" > "$W/edge.caddyfile"
XDG_DATA_HOME="$W/xdg" XDG_CONFIG_HOME="$W/xdg" CF_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$CADDY" adapt --config "$W/edge.caddyfile" --adapter caddyfile > "$W/edge.json" 2> "$W/adapt.err" || { cat "$W/adapt.err"; fail "edge Caddyfile does not adapt"; }
BYTES=$(wc -c < "$W/edge.json"); [ "$BYTES" -le 1500000 ] || fail "adapted edge config is $BYTES bytes (budget 1500000)"
XDG_DATA_HOME="$W/xdg" XDG_CONFIG_HOME="$W/xdg" CF_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$CADDY" validate --config "$W/edge.caddyfile" --adapter caddyfile > "$W/val.out" 2>&1 || { tail -20 "$W/val.out"; fail "edge Caddyfile does not validate"; }
ok "edge Caddyfile adapts ($BYTES bytes) and validates with the image modules"

# 6. behaviour on a throwaway instance (forced client IP via X-Forwarded-For, test config only)
python3 - "$W/Caddyfile" "$W/snip.txt" "$W/herr.txt" <<'PY'
import sys
t = open(sys.argv[1]).read()
def block(start):
    i = t.index(start); k = t.index("{", i); d = 0
    for j in range(k, len(t)):
        d += (t[j] == "{") - (t[j] == "}")
        if d == 0: return t[i:j+1]
open(sys.argv[2], "w").write(block("(geo_fence) {"))
open(sys.argv[3], "w").write(block("handle_errors {"))
PY
run_case() { # run_case <allow-mutation: none|no_us> -> starts instance on :18080
  local snip="$W/snip.$1"
  if [ "$1" = no_us ]; then sed -E 's/ US( |$)/ /' "$W/snip.txt" > "$snip"; else cp "$W/snip.txt" "$snip"; fi
  sed -i "s#db_path [^ ]*#db_path $GEO_DB_FILE#" "$snip"
  { printf '{\n  admin off\n  auto_https off\n  order respond before handle\n  order error first\n  servers {\n    trusted_proxies static 127.0.0.1/32\n    client_ip_headers X-Forwarded-For\n  }\n}\n'
    cat "$snip"; printf '\n:18080 {\n  import geo_fence\n  respond "served" 200\n'; cat "$W/herr.txt"; printf '\n}\n'; } > "$W/test.$1.caddyfile"
  "$CADDY" run --config "$W/test.$1.caddyfile" --adapter caddyfile > "$W/run.$1.log" 2>&1 & echo $! > "$W/pid"
  for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:18080/ 2>/dev/null && break; sleep 0.2; done
}
probe() { # probe <ip> [accept] -> "code|content-type|body-prefix"
  local a=(); [ -n "${2:-}" ] && a=(-H "Accept: $2")
  curl -s -o "$W/body" -w '%{http_code}|%{content_type}|' -H "X-Forwarded-For: $1" "${a[@]}" http://127.0.0.1:18080/ ; head -c 40 "$W/body" | tr -d '\n'
}
expect() { # expect <ip> <code> <label> [accept]
  local got; got="$(probe "$1" "${4:-}")"
  case "$got" in "$2|"*) ok "$3 ($1 -> $2)";; *) tail -5 "$W/run.none.log" 2>/dev/null; fail "$3: $1 expected $2, got $got";; esac
}
run_case none
expect 8.8.8.8 200 "US allowed"
expect 193.0.14.129 200 "NL allowed"
expect 2001:67c:2e8:22::c100:68b 200 "NL over IPv6 allowed"
expect 2a02:6b8::2:242 403 "RU over IPv6 denied"
expect 77.88.8.8 403 "RU denied"
expect 114.114.114.114 403 "CN denied"
expect 203.0.113.9 403 "unplaceable public address denied (fail closed)"
expect 10.0.0.5 200 "mesh 10.0.0.0/24 exempt"
expect 10.1.0.2 200 "wg-public 10.1.0.0/24 exempt"
H="$(probe 77.88.8.8 'text/html,application/xhtml+xml')"
case "$H" in "403|text/html"*"<!doctype html>"*) ok "denied HTML client gets the explanation page";; *) fail "HTML denial page wrong: $H";; esac
grep -q 'Europe and the United States' "$W/body" || fail "denial page lacks the explanation"
A="$(probe 77.88.8.8 'application/json')"
case "$A" in "403|"*"Forbidden") ok "denied API client gets a plain 403";; *) fail "API denial wrong: $A";; esac
RC="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/)"; [ "$RC" = 200 ] || fail "loopback without a forwarded address must be exempt, got $RC"
ok "loopback exempt"
kill "$(cat "$W/pid")"; wait 2>/dev/null || true

# 7. mutation: an allow list without US must deny a US address
run_case no_us
G="$(probe 8.8.8.8)"; case "$G" in 403\|*) ok "mutation (US removed from the allow list) is detected: 8.8.8.8 -> 403";; *) fail "mutation not detected: $G";; esac
kill "$(cat "$W/pid")"; wait 2>/dev/null || true

# 8. mutation: dropping `order error first` must be caught by the static check
sed '/^\s*order error first$/d' "$W/Caddyfile" > "$W/mut.Caddyfile"
if EDGE_CADDYFILE="$W/mut.Caddyfile" bash "$0" >/dev/null 2>&1; then fail "mutation (order error first removed) was not detected"; fi
ok "mutation (order error first removed) is detected"
echo "ok: geo-fence guard"
