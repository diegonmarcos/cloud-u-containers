#!/usr/bin/env bash
# Guard (#1071): the mesh resolver (hickory, 10.0.0.1) must answer the mail hosts
# with a MESH address. A phone on WireGuard that resolves jmap./mails. to the
# public edge reaches Caddy through the public relay (src 10.1.0.1) and gets the
# edge gate's 401 instead of Stalwart. Wildcard * must be mesh, and no explicit
# record may point jmap/mails/mail/imap at a non-mesh address.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
zone="${HICKORY_ZONE:-$root/infra-net_hickory-dns/dist/configs/zones/diegonmarcos.com.zone}"
[ -f "$zone" ] || { echo "FAIL: $zone missing"; exit 1; }
bad=0
grep -Eq '^\*[[:space:]]+IN[[:space:]]+A[[:space:]]+10\.0\.0\.1[[:space:]]*$' "$zone" \
  || { echo "FAIL: wildcard A is not the mesh address 10.0.0.1"; bad=1; }
grep -Eq '^\*[[:space:]]+IN[[:space:]]+AAAA[[:space:]]+fd0c:1d00::1[[:space:]]*$' "$zone" \
  || { echo "FAIL: wildcard AAAA is not the mesh address fd0c:1d00::1"; bad=1; }
for h in jmap mails mail imap; do
  while read -r _ _ type value; do
    case "$type:$value" in
      A:10.0.0.*|AAAA:fd0c:1d00::*) ;;
      *) echo "FAIL: $h record '$type $value' is not a mesh address"; bad=1 ;;
    esac
  done < <(grep -E "^$h[[:space:]]+IN[[:space:]]" "$zone" || true)
done
# #1123: the fleet-only mesh namespace <container>.mesh.diegonmarcos.com must be its own zone,
# wildcarded to the mesh hub, so it never falls through to public DNS.
mz="${HICKORY_MESH_ZONE:-$root/infra-net_hickory-dns/dist/configs/zones/mesh.diegonmarcos.com.zone}"
if [ -f "$mz" ]; then
  grep -Eq '^\*[[:space:]]+IN[[:space:]]+A[[:space:]]+10\.0\.0\.1[[:space:]]*$' "$mz" \
    || { echo "FAIL: mesh.diegonmarcos.com wildcard A is not the mesh address 10.0.0.1"; bad=1; }
  grep -q 'zone = "mesh.diegonmarcos.com"' "$(dirname "$mz")/../named.toml" \
    || { echo "FAIL: named.toml does not serve zone mesh.diegonmarcos.com"; bad=1; }
else
  echo "FAIL: $mz missing (#1123 stage a)"; bad=1
fi
[ "$bad" = 0 ] || exit 1
echo "hickory mesh split-horizon guard: ok"
