#!/usr/bin/env bash
# Guard: the ONE shared 401/403 handler ((edge_errors) in the hub Caddyfile).
#  - browser (Accept: text/html) denied 401/403 -> 302 to the Pages fallback page of the service that owns the host
#  - API / non-HTML client denied -> the plain 403 stays (bearer clients, MCPs, CI are untouched)
# Static: the WG/mesh 403 guards use `error` (so they reach handle_errors) and `order error before handle` is set.
# Runtime: real Caddy, the real (edge_errors) snippet extracted from the rendered dist Caddyfile.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="$HERE/../../.."
CF="$SVC/infra-sec_caddy/dist/configs/Caddyfile"
FB="$SVC/_shared/fallback-services.json"
grep -q '^  order error before handle$' "$CF" || { echo "FAIL: global 'order error before handle' missing"; exit 1; }
if grep -nE '^\s*respond (@not_wg |@not_mesh )?"Forbidden" 403$' "$CF" | head -3 | grep .; then echo "FAIL: a 403 guard still uses respond (bypasses the fallback handler)"; exit 1; fi
CADDY="$(command -v caddy || true)"
[ -n "$CADDY" ] || CADDY="$(ls -d /nix/store/*-caddy-2.*/bin/caddy 2>/dev/null | head -1 || true)"
if [ -z "$CADDY" ]; then
  command -v nix >/dev/null || { echo "FAIL: neither caddy nor nix available" >&2; exit 1; }
  CADDY="$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths nixpkgs#caddy)/bin/caddy"
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/fbtest.XXXXXX")"; trap 'kill $PID 2>/dev/null || true; [ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
P=19491
python3 -I - "$CF" > "$W/snippet" <<'PY'
import sys
# the shared handler is the named route &(edge_error_pages) plus the (edge_errors) snippet that invokes it
out, depth, on = [], 0, False
for l in open(sys.argv[1]).read().split("\n"):
    if l.strip() in ("&(edge_error_pages) {", "(edge_errors) {"): on = True
    if on:
        out.append(l); depth += l.count("{") - l.count("}")
        if depth == 0: on = False
print("\n".join(out))
PY
grep -q "^&(edge_error_pages) {" "$W/snippet" && grep -q "invoke edge_error_pages" "$W/snippet" || { echo "FAIL: &(edge_error_pages) route / (edge_errors) invoke snippet not found"; exit 1; }
# the host map must exist once, not per site
[ "$(grep -c "map {host} {fb_path}" "$CF")" = 1 ] || { echo "FAIL: the fallback host map is rendered more than once"; exit 1; }
{ printf '{\n  admin off\n  auto_https off\n  order respond before handle\n  order error before handle\n}\n'; cat "$W/snippet"
  printf ':%s {\n  bind 127.0.0.1\n  @not_wg not remote_ip 10.0.0.0/24\n  error @not_wg "Forbidden" 403\n  handle {\n    respond "ok"\n  }\n  import edge_errors\n}\n' "$P"; } > "$W/Caddyfile"
"$CADDY" run --config "$W/Caddyfile" --adapter caddyfile >"$W/log" 2>&1 & PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$P/" && break; sleep 0.2; done
BASE="$(jq -r .pages_base "$FB")"
req() { curl -s -o "$W/body" -D "$W/hdr" -w '%{http_code}' -H "Host: $1" -H "Accept: $2" "http://127.0.0.1:$P/x/y"; }
# every declared service: the first host (public host, else mesh name) redirects to ITS page
n=0
while IFS=$'\t' read -r host slug; do
  code=$(req "$host" 'text/html,application/xhtml+xml')
  loc=$(tr -d '\r' < "$W/hdr" | sed -n 's/^[Ll]ocation: //p')
  [ "$code" = 302 ] && [[ "$loc" == "$BASE$slug/?rd=https://$host/x/y" ]] || { echo "FAIL: HTML 403 for $host -> $code $loc (want 302 $BASE$slug/)"; exit 1; }
  n=$((n+1))
done < <(jq -r '[.services[] | .slug as $s | (.hosts + (if .mesh then [.mesh, "cloud." + .mesh] else [] end))[] | [., $s]] | group_by(.[0])[] | select(map(.[1]) | unique | length == 1) | .[0] | @tsv' "$FB")
# API / non-HTML clients keep the plain 403
for acc in 'application/json' '*/*' 'text/event-stream'; do
  code=$(req git.diegonmarcos.com "$acc")
  [ "$code" = 403 ] && grep -q Forbidden "$W/body" && ! grep -qi '^location:' "$W/hdr" || { echo "FAIL: API 403 ($acc) -> $code"; exit 1; }
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: git.diegonmarcos.com' -H 'Authorization: Bearer x' "http://127.0.0.1:$P/x")
[ "$code" = 403 ] || { echo "FAIL: bearer request without Accept -> $code (want 403)"; exit 1; }
# unknown host lands on the Pages index
code=$(req unknown.example.test 'text/html'); loc=$(tr -d '\r' < "$W/hdr" | sed -n 's/^[Ll]ocation: //p')
[[ "$code" = 302 && "$loc" == "$BASE?rd="* ]] || { echo "FAIL: unknown host -> $code $loc"; exit 1; }
echo "ok: HTML 403 -> Pages fallback for $n services; API 403 stays 403"
