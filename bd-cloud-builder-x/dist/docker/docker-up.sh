#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ docker-up.sh — Self-contained cloud-builder launcher             ║
# ║                                                                  ║
# ║ Piped from: docker run --rm $IMG docker-up | sh -s ship all      ║
# ║ Sets up mounts, env vars, runs cloud-builder inside container.   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

OP="${1:-ship}"
VM="${2:-all}"
IMG="ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm:latest"
REPO="https://github.com/diegonmarcos/cloud.git"

# Auto-detect GHCR token
GHCR_TOKEN=""
GHCR_ACTOR=""
if command -v gh >/dev/null 2>&1; then
  GHCR_TOKEN="$(gh auth token 2>/dev/null || true)"
  GHCR_ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
fi

echo "Cloud Builder — $OP $VM"
echo "Image: $IMG"
echo "═══════════════════════════════════════════════"

docker run --rm \
  -v "$HOME/.ssh:/root/.ssh:ro" \
  -v "$HOME/.config/sops:/root/.config/sops:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GITHUB_TOKEN="$GHCR_TOKEN" \
  -e GITHUB_ACTOR="$GHCR_ACTOR" \
  -e FORCE_DEPLOY=1 \
  "$IMG" bash -c "
    git config --global safe.directory /workspace
    git clone --depth 2 --recurse-submodules $REPO /workspace
    cd /workspace && git submodule update --remote
    stdbuf -oL bash .github/workflows/scripts/cloud-builder.sh $OP \$1
  " _ "$VM"
