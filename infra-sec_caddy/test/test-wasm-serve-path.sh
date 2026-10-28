#!/usr/bin/env bash
# #876 the Kotlin/Wasm APK hosts are live: url_scheme.wasm_origin is declared in ../build.json, so
# cloud-infra's apk-web-route.ts gives every web.kind wasm APK route web.serve_path
# (<path_prefix>/<portal_slug>/) and upstream = wasm_origin.upstream, and the renderer serves that
# bundle path behind the edge_auth (Authelia) gate.
#
#  1. declared: build.json declares wasm_origin; the route data carries at least one web.kind wasm
#     APK route, and EVERY one has serve_path == <path_prefix>/<portal_slug>/, upstream == the
#     declared origin, no landing_only, no auth: none, no wg_only; no other route has serve_path;
#  2. nothing else moves: the real render and the render of the same data with the wasm routes
#     turned back into landing redirects are byte-identical once the wasm vhosts are removed, and
#     in the reverted render each of those hosts is a landing redirect again (the pre-wasm_origin
#     shape). Same renderer on both sides, so unrelated renderer changes cannot make it flap;
#  3. every wasm vhost in the real render is gated by edge_auth, rewrites to ITS serve_path inside
#     a `handle` (after forward_auth, which keeps the original URI), proxies to the https origin
#     with its Host, and has no anonymous landing redirect;
#  4. each of those checks can fail (mutations).
#
# Needs: nix (nixpkgs lib), jq, python3; the route data = cloud-infra's 1_cloud-configs/dist/
# build-caddy.json (BUILD_CADDY_JSON, or the sibling checkout). Exits 2 with the reason when the
# data is absent: a missing input is not a pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../src"; BUILD_JSON="$HERE/../build.json"
DATA="${BUILD_CADDY_JSON:-$HERE/../../../cloud-infra/1_cloud-configs/dist/build-caddy.json}"
[ -f "$DATA" ] || { echo "FAIL  route data not found: $DATA (set BUILD_CADDY_JSON)"; exit 2; }
for t in nix jq python3; do command -v $t >/dev/null || { echo "FAIL  $t is required"; exit 2; }; done
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

render() {  # render <src dir> <json> -> stdout
  nix eval --impure --raw --expr "import $1/caddyfile.nix { lib = (import <nixpkgs> {}).lib; caddyRoutes = builtins.fromJSON (builtins.readFile $2); }" 2>"$W/err"
}

# 1 ── the declaration and the derived data
UP="$(jq -r '.caddy_config.url_scheme.wasm_origin.upstream // empty' "$BUILD_JSON")"
PREFIX="$(jq -r '.caddy_config.url_scheme.wasm_origin.path_prefix // empty' "$BUILD_JSON")"
[ "$UP" = "https://diegonmarcos.github.io" ] && [ "$PREFIX" = "/cloud-web/apps" ] \
  && ok "build.json declares url_scheme.wasm_origin ($UP $PREFIX)" || bad "build.json does not declare wasm_origin {upstream https://diegonmarcos.github.io, path_prefix /cloud-web/apps} (got '$UP' '$PREFIX')"
PREFIX="${PREFIX%/}"
jq -c '[.routes[] | select(.apk and (.web.kind == "wasm"))]' "$DATA" > "$W/wasm-routes.json"
N="$(jq length "$W/wasm-routes.json")"
[ "$N" -ge 1 ] && ok "the route data carries $N web.kind wasm APK route(s)" || bad "the route data carries no web.kind wasm APK route (gen-configs not run, or the manifest lost its wasm apps)"
badr="$(jq -r --arg up "$UP" --arg p "$PREFIX" '.[] | select(
    (.web.portal_slug // "") == "" or .web.serve_path != ($p + "/" + .web.portal_slug + "/")
    or .upstream != $up or (.landing_only // false) or (.auth // "") == "none" or (.wg_only // false)
  ) | .domain' "$W/wasm-routes.json")"
[ "$N" -ge 1 ] && [ -z "$badr" ] && ok "every wasm route carries serve_path <prefix>/<slug>/, the origin upstream, and the gate" || bad "wasm routes missing serve_path/upstream or not gated: ${badr:-none present}"
leak="$(jq -r '[.routes[] | select(.web.serve_path and (.web.kind != "wasm")) | .domain] | join(" ")' "$DATA")"
[ -z "$leak" ] && ok "no non-wasm route carries serve_path" || bad "non-wasm routes carry serve_path: $leak"

render "$SRC" "$DATA" > "$W/real.caddy"
[ -s "$W/real.caddy" ] || { bad "the real route data does not render"; head -5 "$W/err"; }

# 2 ── nothing else moves (same renderer, wasm routes reverted to landing redirects)
jq '.routes |= map(if (.apk and .web.kind == "wasm") then (del(.upstream) | .landing_only = true | .web |= del(.serve_path) | .comment = "APK \(.apk): no web target, landing redirect") else . end)' "$DATA" > "$W/nowasm.json"
render "$SRC" "$W/nowasm.json" > "$W/nowasm.caddy"
[ -s "$W/nowasm.caddy" ] || { bad "the reverted route data does not render"; head -5 "$W/err"; }
python3 - "$W/real.caddy" "$W/nowasm.caddy" "$W/wasm-routes.json" <<'PY' && ok "outside the $N wasm vhosts the Caddyfile is byte-identical to the landing-redirect render, where each of them is a landing redirect" || bad "declaring wasm_origin moved something outside the wasm vhosts, or a reverted host is not a landing redirect"
import json,re,sys
hosts=[r["domain"] for r in json.load(open(sys.argv[3]))]
if not hosts: sys.exit("no wasm hosts")
def block(t,h):
    return re.search(r'(?:^  #[^\n]*\n)?^  '+re.escape(h)+r' \{\n.*?(?=^  # |^  [\w.*-][^\n]* \{\n|\Z)',t,re.S|re.M)
def strip(t):
    for h in hosts:
        m=block(t,h)
        if not m: sys.exit("no vhost block for "+h)
        t=t[:m.start()]+t[m.end():]
    return t
real,old=open(sys.argv[1]).read(),open(sys.argv[2]).read()
bad=[h for h in hosts if not block(old,h) or "landing" not in block(old,h).group(0) or "rewrite *" in block(old,h).group(0)]
if bad: sys.exit("reverted hosts are not landing redirects: "+" ".join(bad))
a,b=strip(real),strip(old)
if a!=b:
    import difflib; print("\n".join(list(difflib.unified_diff(b.split("\n"),a.split("\n"),lineterm="",n=0))[:12]),file=sys.stderr); sys.exit(1)
PY

# 3 ── every wasm vhost in the real render
vhost() { python3 - "$1" "$2" <<'PY'
import re,sys
t=open(sys.argv[1]).read(); h=re.escape(sys.argv[2])
m=re.search(r'^  '+h+r' \{\n.*?(?=^  # |^  [\w.*-][^\n]* \{\n|\Z)', t, re.S|re.M)
print(m.group(0) if m else "")
PY
}
check() {  # check <vhost file> <serve_path> -> prints failures
  local f="$1" sp="${2%/}" n=0 ohost="${UP#https://}"
  [ -s "$f" ] || { echo "no vhost block"; return 1; }
  grep -q 'import edge_auth' "$f" || { echo "vhost is not behind the edge_auth gate"; n=1; }
  grep -qF "rewrite * $sp{uri}" "$f" || { echo "no rewrite to the serve_path"; n=1; }
  python3 - "$f" 2>/dev/null <<'PY' || { echo "the rewrite is not inside a handle block"; n=1; }
import sys
t=open(sys.argv[1]).read(); i=t.find("rewrite *"); j=t.rfind("handle {",0,i)
assert i >= 0 and j >= 0 and j < i and t.count("{",j,i) - t.count("}",j,i) >= 1
PY
  grep -qF "reverse_proxy $UP" "$f" || { echo "no proxy to the https origin"; n=1; }
  grep -qF "header_up Host $ohost" "$f" || { echo "no Host header for the origin"; n=1; }
  grep -q 'landing' "$f" && { echo "an anonymous landing redirect leaked in"; n=1; }
  return $n
}
nbad=0; nok=0
while IFS=$'\t' read -r h sp; do
  vhost "$W/real.caddy" "$h" > "$W/v-$h.txt"
  out="$(check "$W/v-$h.txt" "$sp")" && nok=$((nok+1)) || { nbad=$((nbad+1)); echo "      $h: $out"; }
done < <(jq -r '.[] | [.domain, .web.serve_path] | @tsv' "$W/wasm-routes.json")
[ "$N" -ge 1 ] && [ "$nbad" -eq 0 ] && ok "all $nok wasm vhosts are gated, rewrite to their serve_path inside a handle and proxy to the origin" || bad "$nbad of $N wasm vhosts are wrong"

# 4 ── each check can fail (on the first wasm vhost)
IFS=$'\t' read -r H0 SP0 < <(jq -r '.[0] // empty | [.domain, .web.serve_path] | @tsv' "$W/wasm-routes.json")
if [ -n "${H0:-}" ] && [ -s "$W/v-$H0.txt" ]; then
  mutate() {  # mutate <label> <sed> <expected substring>
    sed -e "$2" "$W/v-$H0.txt" > "$W/m.txt"; out="$(check "$W/m.txt" "$SP0")"; rc=$?
    [ $rc -ne 0 ] && grep -qF "$3" <<<"$out" && ok "$1 goes red ($3)" || bad "$1 stayed green or named the wrong thing"
  }
  mutate "no gate"            's/import edge_auth/import nothing/'                    "not behind the edge_auth gate"
  mutate "no rewrite"         's#rewrite \* /#rewrite-off /#'                          "no rewrite to the serve_path"
  mutate "wrong path"         "s#${SP0%/}{uri}#/cloud-web{uri}#"                       "no rewrite to the serve_path"
  mutate "plain-http origin"  's#reverse_proxy https://#reverse_proxy http://#'       "no proxy to the https origin"
  mutate "no Host header"     's/header_up Host [^ ]*//'                               "no Host header"
  mutate "landing redirect"   's#reverse_proxy#redir landing 302\n    reverse_proxy#' "landing redirect leaked"
else
  bad "no wasm vhost to mutate"
fi

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
