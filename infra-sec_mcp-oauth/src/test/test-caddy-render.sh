#!/usr/bin/env bash
# Renders _shared/mcp-oauth.nix with the real infra-sec_caddy/build.json data and
# asserts: (1) the mcp. block carries both handlers + the Authelia forward_auth on
# /authorize, (2) other hosts / absent config render nothing, (3) a path NOT in
# edge_auth.public_open aborts the render. Needs nix (eval only); nixpkgs lib is pinned (NIXPKGS_SRC or the nixos-24.11 flake), never <nixpkgs>.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
# Same pin as infra-sec_caddy/src/test/test-multi-sso.sh: a hosted runner has no NIX_PATH,
# so <nixpkgs/lib> cannot resolve there.
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes"
if [ -n "${NIXPKGS_SRC:-}" ]; then LIBX="import $NIXPKGS_SRC/lib"
else LIBX="(builtins.getFlake \"github:NixOS/nixpkgs/nixos-24.11\").lib"; fi
render(){ # render [cfgOverride nix expr]
  $NIX eval --impure --json --expr "import $HERE/caddy-render.nix { root = $ROOT; lib = ($LIBX); ${1:+cfgOverride = $1;} }"
}
J=$(render)
on=$(jq -r .on <<<"$J")
grep -q '@mcp_oauth_open path ' <<<"$on"
grep -q 'forward_auth ' <<<"$on"
grep -q '@mcp_oauth_authz path /authorize /\*/authorize' <<<"$on"
! grep -q '/introspect' <<<"$on"
[ "$(jq -r .other <<<"$J")" = "" ] && [ "$(jq -r .off <<<"$J")" = "" ]
if render '{host="mcp.diegonmarcos.com";upstream="u";open_paths=["/introspect"];authorize_paths=[];}' >/dev/null 2>&1; then
  echo "FAIL: undeclared path rendered"; exit 1
fi
echo "caddy render: ok"
