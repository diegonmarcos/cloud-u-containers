#!/usr/bin/env bash
# Guard: every ssh alias cloud-superapp-mcp dials has a Host entry.
#
# SUPERAPP_HOSTS once named phone,phone-v6,phone-pub while no config anywhere
# defined them, so every call failed with "Could not resolve hostname" and the
# MCP looked like the phone was offline. The container's ~/.ssh/config gets
# these aliases ONLY from build.json ssh.extra_hosts (derived by cloud-infra
# into /opt/ssh-keys/cloud-superapp-mcp/config), so each alias in
#   - src/compose.nix SUPERAPP_HOSTS, and
#   - device.ts's fallback default
# must be an extra_hosts[].host ("local" excepted: runs on-device, no ssh).
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
declared=$(jq -r '.ssh.extra_hosts[]?.host' build.json | sort -u)
check() { # $1 = where, $2 = comma list
  local a
  [ -n "$2" ] || { echo "FAIL $1: no alias list found"; fail=1; return; }
  for a in ${2//,/ }; do
    [ "$a" = local ] && continue
    if grep -qxF "$a" <<<"$declared"; then echo "ok   $1: $a"
    else echo "FAIL $1: alias '$a' has no build.json ssh.extra_hosts entry"; fail=1; fi
  done
}
check compose.nix "$(sed -n 's/.*SUPERAPP_HOSTS *= *"\([^"]*\)".*/\1/p' src/compose.nix | head -1)"
check device.ts  "$(sed -n 's/.*SUPERAPP_HOSTS ?? "\([^"]*\)".*/\1/p' src/code/lib-mcp/src/device.ts | head -1)"
# Each entry must be complete; the derive resolves wg_client -> mesh address.
bad=$(jq -r '.ssh.extra_hosts[]? | select((.host|type)!="string" or (.wg_client|type)!="string" or (.user|type)!="string" or (.port|type)!="number" or ((.family // "v4")|IN("v4","v6")|not)) | .host // "?"' build.json)
[ -z "$bad" ] || { echo "FAIL incomplete extra_hosts entries: $bad"; fail=1; }
[ "$fail" = 0 ] && echo "PASS superapp-hosts-declared" || exit 1
