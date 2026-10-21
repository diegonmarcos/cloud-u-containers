#!/usr/bin/env bash
# Guard (#1071): the RENDERED Caddyfile keeps the jmap./mails. gate the Cloud Mail app relies on.
#  - a mailbox login (Basic, or a Stalwart Bearer) is never sent to Authelia on the mesh: the vhost
#    uses edge_auth_offmesh (mesh peers keep WG trust) and the unrecognised-Bearer branch is skipped
#    for these two hosts so Stalwart answers its own 401 (application/problem+json);
#  - off the mesh the gate answers (text/html or a redirect), which is the app's "edge" 401.
# Live matrix: infra-sec_caddy/src/test/probe-jmap-auth.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CF="${CADDYFILE:-$HERE/../../dist/configs/Caddyfile}"
fail=0; ok(){ echo "ok   $*"; }; bad(){ echo "FAIL $*" >&2; fail=1; }
for host in jmap mails; do
  block="$(awk -v h="$host.diegonmarcos.com {" '$0 == "  "h {p=1; next} p && /^  [a-z0-9-]+\.diegonmarcos\.com.*\{$/ {exit} p{print}' "$CF")"
  [ -n "$block" ] || { bad "$host vhost missing"; continue; }
  grep -q 'import edge_auth_offmesh' <<<"$block" && ok "$host imports edge_auth_offmesh" || bad "$host lost edge_auth_offmesh"
  grep -q 'import edge_errors' <<<"$block" && ok "$host imports edge_errors" || bad "$host lost edge_errors"
done
n=$(grep -c 'not host jmap.diegonmarcos.com mails.diegonmarcos.com' "$CF")
[ "$n" -ge 3 ] && ok "Bearer passthrough on jmap/mails present in $n gate snippets" || bad "Bearer passthrough (0ec52455) missing: $n < 3"
grep -q 'not remote_ip 10.0.0.0/24 fd0c:1d00::/64' "$CF" && ok "mesh exemption present" || bad "mesh exemption missing"
exit $fail
