#!/usr/bin/env bash
# ============================================================================
# bb-net_wireguard-mesh-ws-tunnel — declarative integrity tester
# ============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_JSON="$PROJ_DIR/build.json"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ wireguard-mesh-ws-tunnel tester  ($PROJ_DIR)"

# ── Phase 1 · file structure ─────────────────────────────────────────────
echo "▶ Phase 1 · structural"
[ -f "$BUILD_JSON" ]                              && ok "build.json present"          || nope "build.json missing"
[ -L "$PROJ_DIR/build.sh" ]                       && ok "build.sh symlinked to engine" || nope "build.sh symlink missing"
[ -f "$PROJ_DIR/src/secrets.yaml" ]               && ok "src/secrets.yaml present (sops convention)" || nope "src/secrets.yaml missing"
[ -f "$PROJ_DIR/0.spec/README.md" ]               && ok "0.spec/README.md present"     || nope "0.spec missing"
for f in src/compose.nix src/flake.nix; do
  [ -f "$PROJ_DIR/$f" ] && ok "$f" || nope "$f missing"
done
[ -L "$PROJ_DIR/src/build.json" ]                 && ok "src/build.json → ../build.json" || nope "src/build.json symlink missing"

# ── Phase 2 · build.json schema ──────────────────────────────────────────
echo "▶ Phase 2 · build.json schema"
name=$(jq -r '.name' "$BUILD_JSON")
[ "$name" = "wireguard-mesh-ws-tunnel" ] && ok "name = $name" || nope "name=$name (expected wireguard-mesh-ws-tunnel)"
host=$(jq -r '.deploy.host' "$BUILD_JSON")
[ "$host" = "gcp-proxy" ] && ok "deploy.host = gcp-proxy (the WG hub)" || nope "deploy.host=$host (expected gcp-proxy)"
domain=$(jq -r '.proxy.primary.domain' "$BUILD_JSON")
[ -n "$domain" ] && [ "$domain" != "null" ] && ok "proxy.primary.domain = $domain" || nope "domain missing"
auth=$(jq -r '.proxy.primary.auth' "$BUILD_JSON")
[ "$auth" = "none" ] && ok "auth = none (wstunnel client has no cookie/2FA — scanner defence on path-prefix)" \
                     || nope "auth=$auth (expected none)"
# Caddy v2 reverse_proxy passes WebSocket upgrades natively; no schema flag needed.
# Confirm proxy.primary follows the canonical { domain, auth } shape (no bespoke fields).
extra=$(jq -r '.proxy.primary | keys | map(select(. != "domain" and . != "auth" and (startswith("_") | not))) | length' "$BUILD_JSON")
[ "$extra" = "0" ] && ok "proxy.primary matches canonical {domain, auth} shape (no bespoke fields)" \
                   || nope "proxy.primary has $extra non-canonical fields — reduce to {domain, auth}"
mem=$(jq -r '.containers.app.resources.mem_limit' "$BUILD_JSON")
[ "$mem" = "64m" ] && ok "mem_limit = 64m"                              || nope "mem_limit=$mem"
netmode=$(jq -r '.containers.app.network_mode' "$BUILD_JSON")
[ "$netmode" = "host" ] && ok "network_mode = host (reaches kernel WG at 127.0.0.1)" || nope "network_mode=$netmode"

# Image is upstream wstunnel
img=$(jq -r '.containers.app.image' "$BUILD_JSON")
[[ "$img" == *"wstunnel"* ]] && ok "image references wstunnel ($img)"   || nope "image=$img (expected wstunnel)"

# Command must include --restrict-to 127.0.0.1:51820 (security gate)
restrict_ok=$(jq -e '.containers.app.command | index("--restrict-to") and (index("127.0.0.1:51820"))' "$BUILD_JSON" >/dev/null 2>&1 && echo y || echo n)
[ "$restrict_ok" = "y" ] && ok "wstunnel --restrict-to 127.0.0.1:51820 (security pin)" || nope "wstunnel server is missing --restrict-to gate"

# Command must include --restrict-http-upgrade-path-prefix ${WSTUNNEL_PATH_PREFIX}
# (wstunnel v10.5.4+ renamed from --http-upgrade-path-prefix)
prefix_ok=$(jq -e '.containers.app.command | index("--restrict-http-upgrade-path-prefix")' "$BUILD_JSON" >/dev/null 2>&1 && echo y || echo n)
[ "$prefix_ok" = "y" ] && ok "wstunnel --restrict-http-upgrade-path-prefix wired (scanner defence)" || nope "no --restrict-http-upgrade-path-prefix flag"
# Command must start with /home/app/wstunnel (image ENTRYPOINT is dumb-init -- ARGV)
binary_ok=$(jq -e '.containers.app.command[0] == "/home/app/wstunnel"' "$BUILD_JSON" >/dev/null 2>&1 && echo y || echo n)
[ "$binary_ok" = "y" ] && ok "command starts with /home/app/wstunnel (dumb-init ENTRYPOINT compatible)" \
                       || nope "command must start with /home/app/wstunnel"
# Bind on all interfaces (Caddy in container can't reach host-localhost)
bind_ok=$(jq -e '.containers.app.command | index("ws://0.0.0.0:8080")' "$BUILD_JSON" >/dev/null 2>&1 && echo y || echo n)
[ "$bind_ok" = "y" ] && ok "wstunnel binds 0.0.0.0:8080 (reachable from Caddy via WG IP)" \
                     || nope "wstunnel must bind ws://0.0.0.0:8080 (not 127.0.0.1)"

# ── Phase 3 · transports declaration (the SoT for the whole VPN) ─────────
echo "▶ Phase 3 · transports SoT"
for k in wg0 wg0-tcp; do
  jq -e ".transports.\"$k\"" "$BUILD_JSON" >/dev/null && ok "transports.$k declared" || nope "transports.$k missing"
done
udp_proto=$(jq -r '.transports.wg0.protocol' "$BUILD_JSON")
[ "$udp_proto" = "udp" ] && ok "transports.wg0.protocol = udp"          || nope "wg0.protocol=$udp_proto"
udp_primary=$(jq -r '.transports.wg0.primary' "$BUILD_JSON")
[ "$udp_primary" = "true" ] && ok "transports.wg0.primary = true"       || nope "wg0.primary=$udp_primary"
tcp_proto=$(jq -r '.transports."wg0-tcp".protocol' "$BUILD_JSON")
[ "$tcp_proto" = "tcp" ] && ok "transports.wg0-tcp.protocol = tcp"      || nope "wg0-tcp.protocol=$tcp_proto"
tcp_fallback=$(jq -r '.transports."wg0-tcp".fallback' "$BUILD_JSON")
[ "$tcp_fallback" = "true" ] && ok "transports.wg0-tcp.fallback = true" || nope "wg0-tcp.fallback=$tcp_fallback"
secret_ref=$(jq -r '.transports."wg0-tcp".wstunnel_path_prefix_secret' "$BUILD_JSON")
[ "$secret_ref" = "WSTUNNEL_PATH_PREFIX" ] && ok "wg0-tcp references WSTUNNEL_PATH_PREFIX secret" || nope "secret_ref=$secret_ref"

# ── Phase 4 · secrets contract ───────────────────────────────────────────
echo "▶ Phase 4 · secrets contract"
required=$(jq -r '.secrets.required[]' "$BUILD_JSON" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
[ "$required" = "WSTUNNEL_PATH_PREFIX" ] && ok "secrets.required = $required" || nope "secrets.required mismatch: '$required'"
grep -q '^WSTUNNEL_PATH_PREFIX:' "$PROJ_DIR/src/secrets.yaml" \
  && ok "src/secrets.yaml declares WSTUNNEL_PATH_PREFIX key" \
  || nope "secrets.yaml missing WSTUNNEL_PATH_PREFIX key"

# ── Phase 5 · cross-references ───────────────────────────────────────────
echo "▶ Phase 5 · sibling cross-references"
PANEL_DATA_SOURCES=$(jq -r '.data_sources | to_entries[] | "\(.key)=\(.value)"' \
  /home/diego/git/cloud/a_solutions/bb-net_wireguard-mesh/build.json 2>/dev/null || true)
echo "$PANEL_DATA_SOURCES" | grep -q "a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json" \
  && ok "panel data_sources point at this folder" \
  || nope "panel data_sources do NOT reference bb-net_wireguard-mesh-ws-tunnel — needs update"

DERIVER=/home/diego/git/cloud/1_configs/src/engines/derive-mesh-snapshot.ts
[ -f "$DERIVER" ] && ok "derive-mesh-snapshot.ts deriver exists" || nope "deriver missing"
grep -q 'bb-net_wireguard-mesh-ws-tunnel/build.json' "$DERIVER" \
  && ok "deriver reads bb-net_wireguard-mesh-ws-tunnel/build.json" \
  || nope "deriver still references the old path — needs update"

echo
if [ "$fail" = 0 ]; then
  printf '▶ \033[32m%d passed, 0 failed\033[0m\n' "$pass"
  exit 0
else
  printf '▶ \033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
