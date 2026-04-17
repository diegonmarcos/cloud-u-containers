#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ship-hm.sh — Self-contained HM deploy inside cloud-builder     ║
# ║                                                                  ║
# ║  Runs INSIDE the builder container. GHA only passes env vars.    ║
# ║  This script: clones → pulls fresh data → secrets → build → ship ║
# ║                                                                  ║
# ║  Required env: VM, SOPS_AGE_KEY, GITHUB_TOKEN, GITHUB_REPOSITORY║
# ║  SSH keys: OCI_SSH_KEY, GCP_PROXY_SSH_KEY, GCP_T4_SSH_KEY       ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Source nix profile + devShell PATH (tools like jq, sops, rsync live here)
[ -f /etc/devshell-path.txt ] && export PATH="$(cat /etc/devshell-path.txt)"
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
export PATH="$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:${PATH:-/usr/bin:/bin}"

VM="${VM:?VM env var required}"
REPO="https://github.com/${GITHUB_REPOSITORY:?}.git"

echo "══════════════════════════════════════════"
echo "  Ship HM: $VM"
echo "══════════════════════════════════════════"

# ── 1. Clone fresh (or use existing workspace) ─────────────────
mkdir -p ~/.ssh
ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null
git config --global --add safe.directory "*"
if [ -d /workspace/.git ]; then
  echo "[1/5] Using existing /workspace"
  cd /workspace
  git pull --ff-only 2>/dev/null || true
else
  echo "[1/5] Cloning $REPO"
  git clone --depth 2 --recurse-submodules "$REPO" /workspace
  cd /workspace
fi
git submodule update --remote
# cloud-data: remote always wins
git -C cloud-data fetch origin main 2>/dev/null && git -C cloud-data reset --hard origin/main 2>/dev/null || true

# ── 1b. WireGuard (if key provided) ─────────────────────────────
if [ -n "${WG_PRIVATE_KEY:-}" ]; then
  echo "[1b/6] Setting up WireGuard"
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

# ── 2. Setup SSH ────────────────────────────────────────────────
echo "[2/6] Setting up SSH for $VM"
# Source of truth: per-VM build.json (NOT cloud-data — that's derived, can be stale)
BUILD_JSON="/workspace/b_infra/home-manager/nixhm-sudo-${VM}/build.json"
if [ ! -f "$BUILD_JSON" ]; then
  echo "FATAL: $BUILD_JSON not found"
  exit 1
fi
HOST=$(jq -r '.vm.network.wg_ip' "$BUILD_JSON")
USER=$(jq -r '.hm.user' "$BUILD_JSON")
if [ -z "$HOST" ] || [ "$HOST" = "null" ] || [ -z "$USER" ] || [ "$USER" = "null" ]; then
  echo "FATAL: build.json missing vm.network.wg_ip ($HOST) or hm.user ($USER)"
  exit 1
fi

# SSH key: read from file path (_FILE) or env var (GHA secrets)
case "$VM" in
  gcp-proxy) KEY_VAR="${GCP_PROXY_SSH_KEY:-}"; KEY_FILE="${SSH_KEY_FILE:-}" ;;
  gcp-t4)    KEY_VAR="${GCP_T4_SSH_KEY:-}";    KEY_FILE="${SSH_KEY_FILE:-}" ;;
  *)         KEY_VAR="${OCI_SSH_KEY:-}";        KEY_FILE="${SSH_KEY_FILE:-}" ;;
esac

if [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ]; then
  cp "$KEY_FILE" ~/.ssh/id_deploy
elif [ -n "$KEY_VAR" ]; then
  echo "$KEY_VAR" > ~/.ssh/id_deploy
else
  echo "FATAL: No SSH key for $VM (set SSH_KEY_FILE or *_SSH_KEY env)"
  exit 1
fi
chmod 600 ~/.ssh/id_deploy
cat > ~/.ssh/config <<EOF
Host ${VM}
  HostName ${HOST}
  User ${USER}
  IdentityFile ~/.ssh/id_deploy
  StrictHostKeyChecking no
  ServerAliveInterval 30
  ServerAliveCountMax 60
EOF
chmod 600 ~/.ssh/config

# ── 3. Setup SOPS ──────────────────────────────────────────────
echo "[3/5] Setting up SOPS"
# SOPS key: file path (_FILE mount) or env var (GHA secrets)
if [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -f "$SOPS_AGE_KEY_FILE" ]; then
  export SOPS_AGE_KEY_FILE
elif [ ! -f ~/.config/sops/age/keys.txt ]; then
  mkdir -p ~/.config/sops/age
  echo "${SOPS_AGE_KEY:?SOPS_AGE_KEY or SOPS_AGE_KEY_FILE required}" > ~/.config/sops/age/keys.txt
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
else
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
fi

# ── 4. Update builder flake.lock (fresh config.json hash) ──────
echo "[4/5] Updating builder flake inputs"
nix flake update config-json --flake /opt/cloud-builder-flake 2>&1 || echo "[builder] flake update skipped"

# ── 5. Ship ─────────────────────────────────────────────────────
echo "[5/6] Running build.sh ship for $VM"
HM_DIR="/workspace/b_infra/home-manager/nixhm-sudo-${VM}"
if [ ! -d "$HM_DIR" ]; then
  echo "FATAL: $HM_DIR does not exist"
  exit 1
fi
cd "$HM_DIR"
bash build.sh ship 2>&1

# ── 6. Activate on VM (docker delivery only) ──────────────────
# All config from build.json — single source of truth
DELIVERY=$(jq -r '.hm.delivery // ""' "$BUILD_JSON")
REMOTE_BUILDER=$(jq -r '.hm.remote_builder // false' "$BUILD_JSON")
HM_IMAGE=$(jq -r '.hm.image // ""' "$BUILD_JSON")

if [ "$DELIVERY" = "docker" ] && [ "$REMOTE_BUILDER" != "true" ] && [ -n "$HM_IMAGE" ] && [ "$HM_IMAGE" != "null" ]; then
  echo "[6/6] Activating on $VM: pull + copy nix store + activate natively"
  # Step A: pull image + run container to copy nix store to host
  ssh "$VM" bash <<ACTIVATE_SSH
set -e
echo "[activate] Pulling $HM_IMAGE:latest"
docker pull $HM_IMAGE:latest 2>&1 | tail -3
echo "[activate] Copying nix store to host"
docker run --rm --privileged \
  -v /:/host \
  -v /nix:/host/nix \
  -v /etc:/host/etc \
  -v /home/$USER:/host/home/$USER \
  $HM_IMAGE:latest 2>&1
# Step B: activate natively on the host (nix is in PATH, no chroot needed)
ACTIVATION_PATH=\$(cat /tmp/.hm-activation-path 2>/dev/null)
if [ -z "\$ACTIVATION_PATH" ]; then
  echo "[activate] FATAL: /tmp/.hm-activation-path not found"
  exit 1
fi
echo "[activate] Running \$ACTIVATION_PATH/activate natively"
# Source nix profile so nix-env/nix-build are in PATH before activate overwrites it
export PATH="\$HOME/.local/bin:\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin"
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
\$ACTIVATION_PATH/activate
echo "[activate] Done — new generation active"
ACTIVATE_SSH
else
  echo "[6/6] Skipped docker activate (delivery=$DELIVERY remote_builder=$REMOTE_BUILDER)"
fi
