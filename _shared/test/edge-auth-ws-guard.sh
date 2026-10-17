#!/usr/bin/env bash
# Guard: every forward_auth in the edge gate must strip Connection and Upgrade,
# otherwise websocket upgrades hang at the edge (notes-sync, 2026-10-17).
set -euo pipefail
tpl="$(dirname "$0")/../edge-auth.caddy.tpl"
awk '
  /^[[:space:]]*forward_auth /{inb=1; c=0; u=0; n++; next}
  inb && /header_up -Connection/{c=1}
  inb && /header_up -Upgrade/{u=1}
  inb && /^[[:space:]]*}[[:space:]]*$/{ if(!c||!u){print "forward_auth block " n " lacks header_up -Connection/-Upgrade"; bad=1}; inb=0 }
  END{ if(n==0){print "no forward_auth found"; exit 1}; exit bad }
' "$tpl"
echo "edge-auth ws guard: ok"
