#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  health.sh — Self-contained health check                        ║
# ║  Runs INSIDE cloud-builder container. GHA passes env vars only.  ║
# ║                                                                  ║
# ║  Required env: WG_PRIVATE_KEY, SOPS_AGE_KEY,                    ║
# ║    GITHUB_TOKEN, GITHUB_REPOSITORY                               ║
# ║  Optional: OIDC_TOKEN                                           ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

[ -f /etc/devshell-path.txt ] && export PATH="$(cat /etc/devshell-path.txt)"
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
export PATH="$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:${PATH:-/usr/bin:/bin}"

REPO="https://github.com/${GITHUB_REPOSITORY:?}.git"

echo "══════════════════════════════════════════"
echo "  Health Check"
echo "══════════════════════════════════════════"

# ── 1. WireGuard ─────────────────────────────────────────────────
if [ -n "${WG_PRIVATE_KEY:-}" ]; then
  echo "[1/4] Setting up WireGuard"
  umask 077
  cat > /tmp/wg0.conf << WGEOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = 10.0.0.200/24

[Peer]
PublicKey = vV/phXUwnCjxACQ5Df11Uw47BzJaK4r85jPYMu2HmDc=
Endpoint = 35.226.147.64:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
WGEOF
  mkdir -p /etc/wireguard
  cp /tmp/wg0.conf /etc/wireguard/wg0.conf
  rm /tmp/wg0.conf
  wg-quick up wg0
  ping -c1 -W3 10.0.0.1 >/dev/null 2>&1 && echo "[wg] Hub reachable" || echo "[wg] Hub not reachable"
fi

# ── 2. SOPS ──────────────────────────────────────────────────────
echo "[2/4] Setting up SOPS"
mkdir -p ~/.config/sops/age
echo "${SOPS_AGE_KEY:?}" > ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# ── 3. Clone repo ────────────────────────────────────────────────
echo "[3/4] Cloning repo"
git config --global --add safe.directory "*"
mkdir -p ~/.ssh
ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null
git clone --depth 2 --recurse-submodules "$REPO" /workspace
cd /workspace
git submodule update --remote

# ── 4. Run health script ────────────────────────────────────────
echo "[4/4] Running health check"
bash .github/workflows/scripts/health-full.sh
