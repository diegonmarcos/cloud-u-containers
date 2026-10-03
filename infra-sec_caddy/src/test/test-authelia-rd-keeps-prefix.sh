#!/usr/bin/env bash
# Guard (#655): a browser that logs in through Authelia must LAND on the
# original prefixed URL and get content — not merely receive a 302.
#
# Runs real Caddy with the real snippets/20-authelia.caddy.tpl inside the same
# `handle_path <prefix>/*` shape caddyfile.nix emits. A stand-in Authelia
# builds rd from X-Forwarded-Uri exactly as the real forward-auth endpoint
# does, and returns 200 once a session cookie is present.
#   1. GET /git/repos (no session) -> 302, rd must name /git/repos
#   2. follow rd WITH the session -> 200 and the upstream's body
# The bug: handle_path strips the prefix before forward_auth, so the default
# X-Forwarded-Uri ({uri}) is /repos and the login lands on an unrouted path.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="${AUTHELIA_TPL:-$HERE/../snippets/20-authelia.caddy.tpl}"
CADDY="$(command -v caddy || true)"
if [ -z "$CADDY" ]; then
  command -v nix >/dev/null || { echo "FAIL: neither caddy nor nix available" >&2; exit 1; }
  CADDY="$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths nixpkgs#caddy)/bin/caddy"
fi
W="$(mktemp -d)"; trap 'kill $PID 2>/dev/null || true; rm -rf "$W"' EXIT
E=19480; A=19481; U=19482
snippet="$(sed -e "s|@AUTHELIA_UPSTREAM@|127.0.0.1:$A|" -e "s|@AUTHELIA_URI@|/api/authz/forward-auth|" \
                -e "s|@AUTHELIA_COPY@|Remote-User|" "$TPL")"
cat > "$W/Caddyfile" <<CF
{
  admin off
  auto_https off
}
:$E {
  handle_path /git/* {
$snippet
    reverse_proxy 127.0.0.1:$U
  }
  handle {
    respond "unrouted" 404
  }
}
:$A {
  @session header Cookie *session=ok*
  handle @session {
    header Remote-User tester
    respond "" 200
  }
  handle {
    redir "https://auth.test/?rd={http.request.header.X-Forwarded-Uri}" 302
  }
}
:$U {
  @repos path /repos
  respond @repos "repos-content" 200
  respond "upstream-404" 404
}
CF
"$CADDY" run --config "$W/Caddyfile" --adapter caddyfile >"$W/log" 2>&1 & PID=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$U/repos" && break; sleep 0.2; done
fail=0
loc="$(curl -s -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:$E/git/repos")"
rd="${loc#*rd=}"
echo "pre-login redirect: $loc"
[ "$rd" = "/git/repos" ] || { echo "FAIL: rd='$rd', expected '/git/repos' (prefix dropped)" >&2; fail=1; }
code_body="$(curl -s -H 'Cookie: session=ok' -w ' %{http_code}' "http://127.0.0.1:$E$rd")"
echo "post-login landing on '$rd': $code_body"
[ "$code_body" = "repos-content 200" ] || { echo "FAIL: post-login landing did not serve upstream content" >&2; fail=1; }
[ $fail = 0 ] && echo "PASS: login returns to the prefixed URL and it serves content"
exit $fail
