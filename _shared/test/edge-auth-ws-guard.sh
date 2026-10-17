#!/usr/bin/env bash
# Guard: every forward_auth in the edge gate must strip Connection and Upgrade,
# otherwise websocket upgrades hang at the edge (notes-sync, 2026-10-17).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bad=0
for tpl in "$root"/_shared/edge-auth.caddy.tpl "$root"/infra-sec_caddy*/src/snippets/2[01]-*.caddy.tpl "$root"/infra-sec_caddy*/dist/configs/Caddyfile; do
[ -f "$tpl" ] || continue
awk '
  /^[[:space:]]*forward_auth [^#]*\{[[:space:]]*$/{inb=1; c=0; u=0; n++; next}
  inb && /header_up -Connection/{c=1}
  inb && /header_up -Upgrade/{u=1}
  inb && /^[[:space:]]*}[[:space:]]*$/{ if(!c||!u){print "forward_auth block " n " lacks header_up -Connection/-Upgrade"; bad=1}; inb=0 }
  END{ if(n==0){print "no forward_auth found"; exit 1}; exit bad }
' "$tpl" || { echo "FAIL: $tpl"; bad=1; }
done
[ "$bad" = 0 ] || exit 1
echo "edge-auth ws guard: ok"
