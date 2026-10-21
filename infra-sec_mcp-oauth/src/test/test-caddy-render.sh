#!/usr/bin/env bash
# Renders _shared/mcp-oauth.nix with the real infra-sec_caddy/build.json data and
# asserts: (1) the mcp. block carries both handlers + the Authelia forward_auth on
# /authorize, (2) other hosts / absent config render nothing, (3) a path NOT in
# edge_auth.public_open aborts the render. Needs nix-instantiate + <nixpkgs/lib>.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
J=$(nix-instantiate --eval --strict --json "$HERE/caddy-render.nix" --arg root "$ROOT")
on=$(jq -r .on <<<"$J")
grep -q '@mcp_oauth_open path ' <<<"$on"
grep -q 'forward_auth ' <<<"$on"
grep -q '@mcp_oauth_authz path /authorize /\*/authorize' <<<"$on"
! grep -q '/introspect' <<<"$on"
[ "$(jq -r .other <<<"$J")" = "" ] && [ "$(jq -r .off <<<"$J")" = "" ]
if nix-instantiate --eval --strict "$HERE/caddy-render.nix" --arg root "$ROOT" \
     --arg cfgOverride '{host="mcp.diegonmarcos.com";upstream="u";open_paths=["/introspect"];authorize_paths=[];}' >/dev/null 2>&1; then
  echo "FAIL: undeclared path rendered"; exit 1
fi
echo "caddy render: ok"
