#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  gen-configs.sh — Self-contained config generation               ║
# ║  Runs INSIDE cloud-builder container. GHA passes env vars only.  ║
# ║                                                                  ║
# ║  Required env: SOPS_AGE_KEY, CLOUD_DATA_DEPLOY_KEY,             ║
# ║    GITHUB_TOKEN, GITHUB_REPOSITORY                               ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

[ -f /etc/devshell-path.txt ] && export PATH="$(cat /etc/devshell-path.txt)"
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
export PATH="$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:${PATH:-/usr/bin:/bin}"

REPO="https://github.com/${GITHUB_REPOSITORY:?}.git"

echo "══════════════════════════════════════════"
echo "  Generate Configs"
echo "══════════════════════════════════════════"

# ── 1. SOPS ──────────────────────────────────────────────────────
mkdir -p ~/.config/sops/age
echo "${SOPS_AGE_KEY:?}" > ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# ── 2. SSH for cloud-data push ───────────────────────────────────
mkdir -p ~/.ssh
echo "${CLOUD_DATA_DEPLOY_KEY:?}" > ~/.ssh/cloud_data_key
chmod 600 ~/.ssh/cloud_data_key
ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/cloud_data_key -o StrictHostKeyChecking=no"

# ── 3. Clone repo ────────────────────────────────────────────────
git config --global --add safe.directory "*"
git clone --depth 2 --recurse-submodules "$REPO" /cloud
cd /cloud
git submodule update --remote
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
export GIT_BASE=/
export GITHUB_WORKSPACE=/cloud

# ── 4. Run gen-configs script ────────────────────────────────────
bash .github/workflows/scripts/ship-gen-configs.sh
