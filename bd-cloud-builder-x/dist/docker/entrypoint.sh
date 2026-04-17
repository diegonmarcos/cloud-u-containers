#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder entrypoint — UNIVERSAL                            ║
# ║                                                                  ║
# ║ Works identically on GHA, Surface, Dagu, any Docker host.       ║
# ║                                                                  ║
# ║ Usage:                                                           ║
# ║   docker run <image> ship oci-apps                               ║
# ║   docker run <image> ship --all                                  ║
# ║   docker run <image> health                                      ║
# ║   docker run <image> bash        (interactive shell)             ║
# ║                                                                  ║
# ║ Secrets: auto-detected from env vars OR mounted files.           ║
# ║   ENV mode (GHA):    SSH_KEY, SOPS_AGE_KEY, GITHUB_TOKEN        ║
# ║   MOUNT mode (local): ~/.ssh, ~/.config/sops mounted into       ║
# ║                        container — script detects and uses them  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

# ── 1. Nix/HM profile ─────────────────────────────────────────────
[ -f /root/.nix-profile/etc/profile.d/nix.sh ] && . /root/.nix-profile/etc/profile.d/nix.sh 2>/dev/null
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
export PATH="$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:/usr/local/bin:$PATH"

# ── 2. Help / passthrough ─────────────────────────────────────────
case "${1:-}" in
  ""|--help|-h)
    IMAGE="ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm"
    echo "cloud-builder — universal CI/CD runner"
    echo ""
    echo "Usage:"
    echo "  docker run --rm $IMAGE cat /opt/cloud-builder/cloud-builder.sh | sh -s <command> [args]"
    echo ""
    echo "Commands:"
    echo "  ship <vm>           Ship services to a VM"
    echo "  ship --all          Ship all VMs"
    echo "  gen-configs         Generate configs (Caddy, DNS, etc.)"
    echo "  ship-hm             Ship home-manager to VMs"
    echo "  ship-reports        Build + push cloud-data-reports image"
    echo "  health              Run health checks"
    echo "  bash                Interactive shell"
    echo ""
    echo "Examples:"
    echo "  ... | sh -s ship oci-apps"
    echo "  ... | sh -s ship --all"
    echo "  ... | sh -s health"
    exit 0
    ;;
  bash|sh|fish)
    # Interactive shell — setup env but don't dispatch
    ;;
  ship|health|gen-configs|ship-hm|ship-reports)
    # Handled below after setup
    ;;
  *)
    # Raw passthrough (e.g. custom script)
    exec "$@"
    ;;
esac

# ── 3. SSH setup (env vars OR mounted files) ──────────────────────
# NEVER write to mounted paths — use /tmp for CI-generated files.
# If ~/.ssh is mounted :ro, it already has what we need.
_ssh_writable() { touch ~/.ssh/.probe 2>/dev/null && rm -f ~/.ssh/.probe; }

if _ssh_writable; then
  # Writable ~/.ssh — CI mode or local dev without :ro mount
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
  if [ -n "${SSH_KEY:-}" ]; then
    echo "$SSH_KEY" > ~/.ssh/id_deploy && chmod 600 ~/.ssh/id_deploy
    echo "[setup] SSH key from env var → ~/.ssh/id_deploy"
  fi
  if [ -n "${SSH_ALIAS:-}" ] && [ -n "${SSH_HOST:-}" ]; then
    cat >> ~/.ssh/config <<EOF
Host ${SSH_ALIAS}
  HostName ${SSH_HOST}
  User ${SSH_USER:-ubuntu}
  IdentityFile ~/.ssh/id_deploy
  StrictHostKeyChecking no
  ServerAliveInterval 30
  ServerAliveCountMax 10
EOF
    chmod 600 ~/.ssh/config
    echo "[setup] SSH config generated for ${SSH_ALIAS}"
  fi
elif [ -f ~/.ssh/id_rsa ] || [ -f ~/.ssh/vault_id_rsa ] || [ -f ~/.ssh/id_deploy ] || [ -f ~/.ssh/config ]; then
  # Read-only mount with content already there — use as-is
  echo "[setup] SSH from mounted ~/.ssh (read-only)"
else
  echo "[setup] WARNING: no SSH keys found (env or mount)"
fi

# ── 4. SOPS setup (env var OR mounted file) ───────────────────────
# Same rule: never write to a read-only mount.
if [ -f ~/.config/sops/age/keys.txt ]; then
  # Already mounted — use directly
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
  echo "[setup] SOPS age key from mounted file"
elif [ -n "${SOPS_AGE_KEY:-}" ]; then
  # CI mode: write to /tmp (always writable)
  mkdir -p /tmp/sops-age
  echo "$SOPS_AGE_KEY" > /tmp/sops-age/keys.txt
  export SOPS_AGE_KEY_FILE=/tmp/sops-age/keys.txt
  echo "[setup] SOPS age key from env var → /tmp"
else
  echo "[setup] WARNING: no SOPS age key found"
fi

# ── 5. GHCR login ─────────────────────────────────────────────────
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin 2>/dev/null
  echo "[setup] GHCR authenticated"
elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
  gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null || echo diegonmarcos)" --password-stdin 2>/dev/null
  echo "[setup] GHCR authenticated via gh CLI"
fi

# ── 6. WireGuard (if key provided) ────────────────────────────────
if [ -n "${WG_PRIVATE_KEY:-}" ]; then
  SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO="sudo"
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
  $SUDO mkdir -p /etc/wireguard
  $SUDO cp /tmp/wg0.conf /etc/wireguard/wg0.conf
  rm /tmp/wg0.conf
  $SUDO wg-quick up wg0 2>/dev/null && echo "[setup] WireGuard up" || echo "[setup] WireGuard failed (non-fatal)"
fi

# ── 7. Rebase all repos (baked at build time under ~/git/) ───────
GIT_ROOT="$HOME/git"
git config --global --add safe.directory "*"

echo "[setup] Syncing all repos..."
for repo in cloud cloud-data unix front tools; do
  dir="$GIT_ROOT/$repo"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch origin main 2>/dev/null \
      && git -C "$dir" reset --hard origin/main 2>/dev/null \
      && echo "[setup] Synced $repo" \
      || echo "[setup] Sync failed for $repo (non-fatal)"
  fi
done
git -C "$GIT_ROOT/cloud" submodule update --init --recursive 2>/dev/null

WORKSPACE="$GIT_ROOT/cloud"
cd "$WORKSPACE"
echo "[setup] Ready: $(pwd) @ $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ── 8. Dispatch ────────────────────────────────────────────────────
SCRIPTS=".github/workflows/scripts"
CMD="$1"; shift

case "$CMD" in
  ship)
    VM="${1:-}"
    if [ "$VM" = "--all" ] || [ -z "$VM" ]; then
      exec bash "$SCRIPTS/cloud-ship-orchestrate-portable.sh" "$@"
    else
      export SSH_ALIAS="${SSH_ALIAS:-$VM}"
      export CHANGED_DIRS="${CHANGED_DIRS:-}"
      exec bash "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" "$VM" "$@"
    fi
    ;;
  health)
    exec bash "$SCRIPTS/cloud-health-full.sh" "$@"
    ;;
  gen-configs)
    exec bash "$SCRIPTS/cloud-ship-orchestrate-gen-configs.sh" "$@"
    ;;
  ship-hm)
    exec bash "$SCRIPTS/cloud-ship-ci-builder-dispatch.sh" ship-hm "$@"
    ;;
  ship-reports)
    CLOUD_DATA_SCRIPTS="$HOME/git/cloud-data/.github/workflows/scripts"
    exec bash "$CLOUD_DATA_SCRIPTS/ship-reports.sh" "$@"
    ;;
  bash|sh)
    exec bash "$@"
    ;;
  fish)
    exec fish "$@"
    ;;
esac
