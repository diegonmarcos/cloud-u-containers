#!/usr/bin/env bash
# #876 the renderer honours route.web.serve_path (a Kotlin/Wasm APK host, derived from
# web.kind wasm + url_scheme.wasm_origin by cloud-infra's apk-web-route.ts).
#
#  1. byte-identical: with no route carrying serve_path (wasm_origin undeclared), the renderer
#     produces EXACTLY what the renderer before this change produced, on the real route data;
#  2. a wasm route renders a vhost that is gated by the shared edge_auth import, rewrites the path to
#     serve_path INSIDE a `handle` (after the gate's forward_auth, which keeps the original URI) and
#     proxies to the https origin with its Host; and proves each of those checks can fail.
#
# Needs: nix (nixpkgs lib), jq, python3, git; the route data = cloud-infra's 1_cloud-configs/dist/
# build-caddy.json (BUILD_CADDY_JSON, or the sibling checkout). Exits 2 with the reason when the
# data is absent: a missing input is not a pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../src"
BASE_REV="${BASE_REV:-9003de2a}"   # the commit whose caddyfile.nix is the pre-change renderer
DATA="${BUILD_CADDY_JSON:-$HERE/../../../cloud-infra/1_cloud-configs/dist/build-caddy.json}"
[ -f "$DATA" ] || { echo "FAIL  route data not found: $DATA (set BUILD_CADDY_JSON)"; exit 2; }
for t in nix jq python3 git; do command -v $t >/dev/null || { echo "FAIL  $t is required"; exit 2; }; done
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

render() {  # render <src dir> <json> -> stdout
  nix eval --impure --raw --expr "import $1/caddyfile.nix { lib = (import <nixpkgs> {}).lib; caddyRoutes = builtins.fromJSON (builtins.readFile $2); }" 2>"$W/err"
}
# the pre-change renderer, beside the current one so its relative imports (../../_shared) resolve
mkdir -p "$W/old/src"; git -C "$HERE" show "$BASE_REV:infra-sec_caddy/src/caddyfile.nix" > "$SRC/.caddyfile.base.nix" 2>/dev/null \
  || { echo "FAIL  cannot read caddyfile.nix at $BASE_REV"; exit 2; }
trap 'rm -rf "$W" "$SRC/.caddyfile.base.nix"' EXIT
renderold() { nix eval --impure --raw --expr "import $SRC/.caddyfile.base.nix { lib = (import <nixpkgs> {}).lib; caddyRoutes = builtins.fromJSON (builtins.readFile $1); }" 2>"$W/err"; }

# 1 ── byte-identical when nothing carries serve_path
[ "$(jq '[.routes[] | select(.web.serve_path)] | length' "$DATA")" = 0 ] && ok "the route data has no serve_path (wasm_origin undeclared)" || bad "the route data already carries serve_path"
render "$SRC" "$DATA" > "$W/new.caddy"; renderold "$DATA" > "$W/old.caddy"
[ -s "$W/new.caddy" ] && [ -s "$W/old.caddy" ] && cmp -s "$W/new.caddy" "$W/old.caddy" && ok "byte-identical Caddyfile with wasm_origin undeclared ($(wc -c < "$W/new.caddy") bytes)" || { bad "output differs from the pre-change renderer"; head -5 "$W/err"; }

# 2 ── a wasm route
host="cloud-calc.diegonmarcos.com"
jq --arg h "$host" '.routes |= map(if .domain == $h then del(.landing_only) | . + {upstream:"https://diegonmarcos.github.io", comment:"APK cloud-calc: web target wasm bundle cloud-calc (Authelia-gated)", web:{kind:"wasm", portal_slug:"cloud-calc", serve_path:"/cloud-web/apps/cloud-calc/"}} else . end)' "$DATA" > "$W/wasm.json"
[ "$(jq --arg h "$host" '[.routes[] | select(.domain == $h)] | length' "$W/wasm.json")" = 1 ] || { echo "FAIL  the data has no single $host route to turn into a wasm route"; exit 2; }
vhost() { python3 - "$1" "$host" <<'PY'
import re,sys
t=open(sys.argv[1]).read(); h=re.escape(sys.argv[2])
m=re.search(r'^  '+h+r' \{\n.*?(?=^  # |^  [\w.*-][^\n]* \{\n|\Z)', t, re.S|re.M)
print(m.group(0) if m else "")
PY
}
check() {  # check <vhost file> -> prints failures
  local f="$1" n=0
  [ -s "$f" ] || { echo "no vhost block for $host"; return 1; }
  grep -q 'import edge_auth' "$f" || { echo "vhost is not behind the edge_auth gate"; n=1; }
  grep -q 'rewrite \* /cloud-web/apps/cloud-calc{uri}' "$f" || { echo "no rewrite to the serve_path"; n=1; }
  python3 - "$f" 2>/dev/null <<'PY' || { echo "the rewrite is not inside a handle block"; n=1; }
import re,sys
t=open(sys.argv[1]).read(); i=t.find("rewrite *"); j=t.rfind("handle {",0,i)
assert i >= 0 and j >= 0 and j < i and t.count("{",j,i) - t.count("}",j,i) >= 1
PY
  grep -q 'reverse_proxy https://diegonmarcos.github.io' "$f" || { echo "no proxy to the https origin"; n=1; }
  grep -q 'header_up Host diegonmarcos.github.io' "$f" || { echo "no Host header for the origin"; n=1; }
  grep -q 'landing' "$f" && { echo "an anonymous landing redirect leaked in"; n=1; }
  return $n
}
render "$SRC" "$W/wasm.json" > "$W/wasm.caddy"; vhost "$W/wasm.caddy" > "$W/v.txt"
out="$(check "$W/v.txt")" && ok "the wasm vhost is gated, rewrites inside a handle and proxies to the origin" || { bad "the wasm vhost is wrong: $out"; }
# the other vhosts did not move: the new render minus the new vhost equals the old render
python3 - "$W/wasm.caddy" "$W/new.caddy" "$host" <<'PY' && ok "no other vhost changed when the route becomes wasm" || bad "turning the route into wasm changed other vhosts"
import re,sys
h=re.escape(sys.argv[3])
def strip(p):
    return re.sub(r'(?:^  #[^\n]*\n)?^  '+h+r' \{\n.*?(?=^  # |^  [\w.*-][^\n]* \{\n|\Z)','',open(p).read(),count=1,flags=re.S|re.M).strip()
a,b=strip(sys.argv[1]),strip(sys.argv[2])
if a!=b:
    import difflib; print("\n".join(list(difflib.unified_diff(b.split("\n"),a.split("\n"),lineterm="",n=0))[:12]), file=sys.stderr)
sys.exit(0 if a==b else 1)
PY

# 3 ── each check can fail
mutate() {  # mutate <label> <sed> <expected substring>
  sed -e "$2" "$W/v.txt" > "$W/m.txt"; out="$(check "$W/m.txt")"; rc=$?
  [ $rc -ne 0 ] && grep -qF "$3" <<<"$out" && ok "$1 goes red ($3)" || bad "$1 stayed green or named the wrong thing"
}
mutate "no gate"            's/import edge_auth/import nothing/'                         "not behind the edge_auth gate"
mutate "no rewrite"         's#rewrite \* /cloud-web#rewrite-off#'                                  "no rewrite to the serve_path"
mutate "wrong path"         's#/cloud-web/apps/cloud-calc{uri}#/cloud-web{uri}#'          "no rewrite to the serve_path"
mutate "plain-http origin"  's#reverse_proxy https://#reverse_proxy http://#'            "no proxy to the https origin"
mutate "no Host header"     's/header_up Host diegonmarcos.github.io//'                  "no Host header"
mutate "landing redirect"   's#reverse_proxy#redir landing 302\n    reverse_proxy#'      "landing redirect leaked"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
