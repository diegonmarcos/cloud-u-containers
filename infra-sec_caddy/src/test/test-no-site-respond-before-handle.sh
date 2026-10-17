#!/usr/bin/env bash
# Guard: the global options carry `order respond before handle`, so a site-level
# plain `respond` (no matcher) runs BEFORE every `handle` in that site and answers
# every request itself. mta-sts.diegonmarcos.com shipped a trailing `respond 404`
# and served 404 for its own policy file (2026-10-17). A fallback must be wrapped:
#   handle { respond 404 }
#
# Part 1 (static): no site in either rendered Caddyfile has a bare top-level
#   `respond <non-matcher> ...` next to a `handle`/`handle_path`.
# Part 2 (runtime): real Caddy with the same `order respond before handle`, the
#   real 90-mta-sts template: GET <policy path> must be 200 with the policy body,
#   any other path 404.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="$HERE/../../.."
python3 -I - "$SVC/infra-sec_caddy/dist/configs/Caddyfile" "$SVC/infra-sec_caddy-public/dist/configs/Caddyfile" <<'PY'
import re, sys
bad = []
for f in sys.argv[1:]:
    depth = 0; cur = None
    for i, l in enumerate(open(f).read().split("\n")):
        m = re.match(r"^  (\S.*) \{$", l)
        if depth == 0 and m and not l.strip().startswith(("(", "#")):
            cur = {"name": m.group(1), "line": i, "handle": False, "resp": []}
        if cur:
            s = l.strip()
            if re.match(r"^handle(_path)?\b", s): cur["handle"] = True
            if depth == 1 and re.match(r"^respond [^@]", s): cur["resp"].append(i + 1)
        depth += l.count("{") - l.count("}")
        if cur and depth == 0 and i > cur["line"]:
            if cur["handle"] and cur["resp"]: bad.append((f.split("/")[-4], cur["name"], cur["resp"]))
            cur = None
if bad:
    for b in bad: print("FAIL: bare site-level respond beside handle (runs first under `order respond before handle`):", b)
    sys.exit(1)
print("ok: no bare site-level respond next to a handle")
PY
CADDY="$(command -v caddy || true)"
[ -n "$CADDY" ] || CADDY="$(ls -d /nix/store/*-caddy-2.*/bin/caddy 2>/dev/null | head -1 || true)"
if [ -z "$CADDY" ]; then
  command -v nix >/dev/null || { echo "FAIL: neither caddy nor nix available" >&2; exit 1; }
  CADDY="$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths nixpkgs#caddy)/bin/caddy"
fi
W="$(mktemp -d)"; trap 'kill $PID 2>/dev/null || true; rm -rf "$W"' EXIT
P=19490
sed -e 's|@MTA_DOMAIN@|:'"$P"'|' -e '/@PUBLIC_BIND_LINE@/d' -e '/@SEC_NO_LIMIT@/d' -e '/@EDGE_GATE@/d' \
    -e '/^    tls {$/,/^    }$/d' \
    -e 's|@MTA_POLICY_PATH@|/.well-known/mta-sts.txt|' -e 's|@MTA_MODE@|enforce|' \
    -e 's|@MTA_MX_LINES@|mx: mx.example.test|' -e 's|@MTA_MAX_AGE@|604800|' \
    "$HERE/../snippets/90-mta-sts.caddy.tpl" > "$W/site"
{ printf '{\n  admin off\n  auto_https off\n  order respond before handle\n}\n'; cat "$W/site"; } > "$W/Caddyfile"
"$CADDY" run --config "$W/Caddyfile" --adapter caddyfile >"$W/log" 2>&1 & PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$P/" && break; sleep 0.2; done
code=$(curl -s -o "$W/body" -w '%{http_code}' "http://127.0.0.1:$P/.well-known/mta-sts.txt")
[ "$code" = 200 ] && grep -q 'version: STSv1' "$W/body" || { echo "FAIL: policy path -> $code (want 200 + policy)"; cat "$W/log" | tail -5; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P/other")
[ "$code" = 404 ] || { echo "FAIL: other path -> $code (want 404)"; exit 1; }
echo "ok: mta-sts policy 200, fallback 404 under 'order respond before handle'"
