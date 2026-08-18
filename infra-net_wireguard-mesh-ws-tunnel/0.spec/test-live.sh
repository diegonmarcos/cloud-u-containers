#!/usr/bin/env bash
# ============================================================================
# test-live.sh — end-to-end integration tester for the deployed WG mesh
#                 + wstunnel TCP/443 fallback framework.
# ----------------------------------------------------------------------------
# Exercises the LIVE running system across all 3 components:
#   • cloud:   bb-net_wireguard-mesh-ws-tunnel container on gcp-proxy
#   • cloud:   Caddy reverse-proxy at vpn.diegonmarcos.com
#   • laptop:  ~/git/cloud-unix/.../wireguard-wstunnel.nix activation outputs
#
# Sibling: 0.spec/test.sh (declarative integrity, build-time)
#          This one assumes test.sh passed and validates DEPLOY state.
#
# Pre-reqs:
#   • SSH alias gcp-proxy reachable via WG (10.0.0.1:22 open)
#   • home-manager has been switched once: build.sh switch
#   • bb-net_wireguard-mesh-ws-tunnel shipped: build.sh ship
#
# Exit 0 = all green. Exit 1 = at least one failure.
# ============================================================================
set -u
# NOTE: not using -e — we want to keep counting failures, not bail on first.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT/src/secrets.yaml"
HM_MOD="$HOME/git/cloud-unix/ba_flakes_desktop/src/modules/wireguard-wstunnel.nix"
DOMAIN="$(jq -r '.domain' "$ROOT/build.json")"
WG_HUB="10.0.0.1"
WG_PORT="8080"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ wireguard-mesh framework — LIVE integration tester"
echo "  domain=$DOMAIN  wg-hub=$WG_HUB:$WG_PORT"

# ── Phase 1 · pre-reqs ──────────────────────────────────────────────────
echo "▶ Phase 1 · pre-reqs"
command -v ssh    >/dev/null 2>&1 && ok "ssh installed"    || nope "ssh missing"
command -v curl   >/dev/null 2>&1 && ok "curl installed"   || nope "curl missing"
command -v sops   >/dev/null 2>&1 && ok "sops installed"   || nope "sops missing"
command -v jq     >/dev/null 2>&1 && ok "jq installed"     || nope "jq missing"

# ── Phase 2 · WG reachability (public:22 closed by design, WG:22 open) ──
echo "▶ Phase 2 · WG mesh reachability"
if timeout 6 bash -c "echo > /dev/tcp/$WG_HUB/22" 2>/dev/null; then
  ok "WG hub $WG_HUB:22 reachable from laptop"
else
  nope "WG hub $WG_HUB:22 unreachable — is wg0 up?"
  echo "    hint: sudo wg-quick up wg0"
fi
ssh_out=$(ssh -o ConnectTimeout=8 -o BatchMode=yes gcp-proxy "echo OK" 2>&1)
[ "$ssh_out" = "OK" ] && ok "ssh gcp-proxy alias resolves + authenticates" \
                     || nope "ssh gcp-proxy failed: $ssh_out"

# ── Phase 3 · container state on gcp-proxy ─────────────────────────────
echo "▶ Phase 3 · container state"
status=$(ssh -o ConnectTimeout=8 gcp-proxy "docker ps --format '{{.Status}}' --filter name=wireguard-mesh-ws-tunnel" 2>/dev/null)
if [[ "$status" == Up* ]]; then
  ok "container Up: $status"
else
  nope "container not Up: '$status'"
fi
# Listener on 0.0.0.0:8080 (any interface — Caddy reaches via WG IP)
listen=$(ssh -o ConnectTimeout=8 gcp-proxy "ss -tlnp 2>/dev/null | grep ':$WG_PORT' | head -1" 2>/dev/null)
[ -n "$listen" ] && ok "wstunnel listener present: $(echo "$listen" | awk '{print $4}')" \
                  || nope "no wstunnel listener on :$WG_PORT"
# Ensure binding is 0.0.0.0 (or :: ), NOT 127.0.0.1 alone (Caddy in a
# container can't reach host-localhost; needs WG-IP exposure).
case "$listen" in
  *0.0.0.0:$WG_PORT*|*::*$WG_PORT*)
    ok "listener bound on all-interfaces (Caddy can reach via WG IP)" ;;
  *127.0.0.1:$WG_PORT*)
    nope "listener bound 127.0.0.1 only — Caddy container can't reach host-localhost" ;;
  *)
    nope "unexpected listener bind: $listen" ;;
esac

# ── Phase 4 · sops secret round-trip ────────────────────────────────────
echo "▶ Phase 4 · sops secret round-trip"
PREFIX_LOCAL=$(sops -d "$SECRETS" 2>/dev/null | awk '/^WSTUNNEL_PATH_PREFIX:/ {print $2}')
[ "${#PREFIX_LOCAL}" = "64" ] && ok "local sops decrypt → 64-char hex (${PREFIX_LOCAL:0:8}…${PREFIX_LOCAL: -8})" \
                              || nope "local decrypt produced ${#PREFIX_LOCAL}-char value"
PREFIX_REMOTE=$(ssh -o ConnectTimeout=8 gcp-proxy "docker exec wireguard-mesh-ws-tunnel env 2>/dev/null | awk -F= '/^WSTUNNEL_PATH_PREFIX=/{print \$2}'" 2>/dev/null)
[ -n "$PREFIX_REMOTE" ] && ok "remote container env var is set" \
                        || nope "remote container has no WSTUNNEL_PATH_PREFIX"
[ "$PREFIX_LOCAL" = "$PREFIX_REMOTE" ] && ok "local sops value matches remote container env (round-trip ✓)" \
                                       || nope "round-trip MISMATCH: local≠remote"

# ── Phase 5 · process is wstunnel with correct flags ───────────────────
echo "▶ Phase 5 · process inspection"
args=$(ssh -o ConnectTimeout=8 gcp-proxy "docker inspect wireguard-mesh-ws-tunnel --format '{{json .Args}}'" 2>/dev/null)
echo "$args" | grep -q '/home/app/wstunnel' && ok "exec path = /home/app/wstunnel" \
                                              || nope "wrong exec path in container args"
echo "$args" | grep -qF -- '--restrict-to' && ok "--restrict-to flag present (only forwards to 127.0.0.1:51820)" \
                                            || nope "--restrict-to flag missing"
echo "$args" | grep -qF -- '--restrict-http-upgrade-path-prefix' \
  && ok "--restrict-http-upgrade-path-prefix flag present (scanner defence)" \
  || nope "scanner-defence flag missing"
echo "$args" | grep -q "$PREFIX_LOCAL" \
  && ok "secret hex correctly substituted into command at runtime" \
  || nope "secret hex NOT in container args — substitution failed"

# ── Phase 6 · Caddy route declared + dialing the right upstream ────────
echo "▶ Phase 6 · Caddy reverse-proxy"
upstream=$(ssh -o ConnectTimeout=8 gcp-proxy "docker exec caddy curl -s localhost:2019/config/apps/http/servers/srv0/routes/" 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for route in data:
    match = route.get('match', [{}])[0]
    if any('$DOMAIN' in h for h in match.get('host', [])):
        for sub in route.get('handle', [{}])[0].get('routes', []):
            for h in sub.get('handle', []):
                if h.get('handler') == 'reverse_proxy':
                    print(h.get('upstreams', [{}])[0].get('dial', ''))
                    sys.exit()
" 2>/dev/null)
[ -n "$upstream" ] && ok "Caddy route for $DOMAIN exists, upstream=$upstream" \
                   || nope "no Caddy route for $DOMAIN"
[ "$upstream" = "$WG_HUB:$WG_PORT" ] && ok "upstream points at WG-hub:$WG_PORT (matches listener)" \
                                     || nope "upstream=$upstream, expected $WG_HUB:$WG_PORT"

# ── Phase 7 · live HTTP ─────────────────────────────────────────────────
echo "▶ Phase 7 · live HTTP probes"
# 7a: any path through Caddy → wstunnel rejects (400) → NOT 502.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$DOMAIN/" 2>/dev/null)
case "$code" in
  502) nope "https://$DOMAIN/ → 502 (Caddy can't reach wstunnel)" ;;
  400|404|405) ok "https://$DOMAIN/ → $code (wstunnel reachable, rejected non-WS)" ;;
  *)   nope "https://$DOMAIN/ → unexpected $code" ;;
esac
# 7b: WS upgrade attempt with the SECRET prefix produces a wstunnel-side
# log entry (we'd need real WS client to get 101; curl's fake handshake
# yields rejected-bad-upgrade — but logs prove the path-prefix matches).
# Capture the line count BEFORE the probe so we can assert log growth.
log_before=$(ssh -o ConnectTimeout=8 gcp-proxy "docker logs wireguard-mesh-ws-tunnel 2>&1 | wc -l" 2>/dev/null)
# Two probes (occasional log buffering on a quiet container can drop a single
# probe's "Accepting connection" line before the read; double the signal).
for i in 1 2; do
  curl -sI --max-time 8 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
    "https://$DOMAIN/$PREFIX_LOCAL/v$i" >/dev/null 2>&1
done
sleep 4
log_after=$(ssh -o ConnectTimeout=8 gcp-proxy "docker logs wireguard-mesh-ws-tunnel 2>&1 | wc -l" 2>/dev/null)
recent=$(ssh -o ConnectTimeout=8 gcp-proxy "docker logs --tail 30 wireguard-mesh-ws-tunnel 2>&1" 2>/dev/null)
if [ "${log_after:-0}" -gt "${log_before:-0}" ] && echo "$recent" | grep -q 'Accepting connection'; then
  ok "wstunnel saw the probes (log line count grew $log_before→$log_after; 'Accepting connection' present)"
else
  nope "wstunnel didn't log probes — log lines $log_before→$log_after; Caddy may not be forwarding"
fi
# Defer the prefix-acceptance proof to Phase 8: a fake-prefix probe MUST
# produce "Rejecting connection with bad upgrade request" — if Phase 8
# passes, the restriction flag is being honored, which means a real-prefix
# probe is also being routed correctly. (We can't directly assert
# acceptance here because curl -I sends a HEAD, which wstunnel's upgrade
# validation rejects for protocol reasons unrelated to the path-prefix.)

# ── Phase 8 · scanner defence ───────────────────────────────────────────
echo "▶ Phase 8 · scanner defence (wrong-prefix → reject)"
fake_prefix="0000000000000000000000000000000000000000000000000000000000000000"
curl -sI --max-time 8 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "https://$DOMAIN/$fake_prefix/v1" >/dev/null 2>&1
sleep 2
fake_log=$(ssh -o ConnectTimeout=8 gcp-proxy "docker logs --since 8s wireguard-mesh-ws-tunnel 2>&1" 2>/dev/null)
echo "$fake_log" | grep -qE 'Rejecting|Invalid|bad upgrade' \
  && ok "wrong-prefix request explicitly rejected by wstunnel" \
  || nope "no rejection log line — restriction may not be active"

# ── Phase 9 · laptop home-manager activation outputs ───────────────────
echo "▶ Phase 9 · laptop activation outputs"
[ -x "$HOME/.local/bin/wg-tcp" ] && ok "wg-tcp helper at ~/.local/bin/wg-tcp (executable)" \
                                 || nope "wg-tcp helper missing or not executable"
if [ -x "$HOME/.local/bin/wg-tcp" ]; then
  out=$("$HOME/.local/bin/wg-tcp" status 2>&1 | head -1)
  echo "$out" | grep -qi 'wstunnel-client' && ok "wg-tcp status reports wstunnel-client unit" \
                                            || nope "wg-tcp status output unexpected: $out"
fi
# Systemd-user unit declared (opt-in: WantedBy=[])
if systemctl --user list-unit-files 2>/dev/null | grep -q '^wstunnel-client'; then
  ok "systemd-user unit wstunnel-client is registered"
else
  nope "wstunnel-client.service not registered with user systemd"
fi
# wg0-tcp.conf present (rendered by activation)
[ -f "$HOME/.config/wireguard/wg0-tcp.conf" ] && ok "wg0-tcp.conf rendered by hm activation" \
                                              || nope "wg0-tcp.conf missing"
# .wstunnel-secret present (sops-decrypted at activation; symlink or file)
if [ -e "$HOME/.config/wireguard/.wstunnel-secret" ]; then
  ok ".wstunnel-secret present (sops-decrypted)"
else
  printf '  \033[33m–\033[0m .wstunnel-secret absent (expected: hm activation does not auto-decrypt; run sops -d > %s/.config/wireguard/.wstunnel-secret before wg-tcp up)\n' "$HOME"
fi
# Module file is the source of truth — sanity that flake.nix imports it
flake_imports=$( grep -c 'wireguard-wstunnel.nix' "$HOME/git/cloud-unix/ba_flakes_desktop/src/flake.nix" 2>/dev/null )
[ "$flake_imports" -ge 1 ] && ok "flake.nix imports wireguard-wstunnel.nix" \
                           || nope "module not imported in flake.nix"

# ── Phase 10 · declarative testers (regression check) ──────────────────
echo "▶ Phase 10 · regression: declarative testers still green"
for t in \
  "$ROOT/0.spec/test.sh" \
  "$HOME/git/cloud-infra/a_solutions/bb-net_wireguard-mesh/0.spec/test.sh" \
  "${HM_MOD%.nix}.test.sh" \
  "$HOME/git/cloud-infra/9_others/src/engine/test-derivers-json.sh"
do
  # Use the bare filename so the label is meaningful regardless of nesting
  name=$(basename "$t")
  if [ -x "$t" ]; then
    if "$t" >/tmp/test-live-sub.log 2>&1; then
      passcount=$(grep -oE '[0-9]+ passed' /tmp/test-live-sub.log | head -1)
      ok "$name → $passcount, 0 failed"
    else
      tail=$(tail -3 /tmp/test-live-sub.log)
      nope "$name failed — last lines: $tail"
    fi
  else
    nope "tester not found/executable: $t"
  fi
done

# ── summary ─────────────────────────────────────────────────────────────
echo
total=$((pass + fail))
if [ "$fail" = 0 ]; then
  printf '▶ \033[32m%d/%d passed\033[0m — framework live + healthy\n' "$pass" "$total"
  exit 0
else
  printf '▶ \033[31m%d/%d passed, %d failed\033[0m\n' "$pass" "$total" "$fail"
  exit 1
fi
