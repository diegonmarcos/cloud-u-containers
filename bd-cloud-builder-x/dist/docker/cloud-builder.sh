#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder.sh — Universal Launcher                           ║
# ║                                                                  ║
# ║ Runs ON THE HOST after extraction from the image:                ║
# ║                                                                  ║
# ║   docker run --rm ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm║
# ║     cat /opt/cloud-builder/cloud-builder.sh | sh -s ship oci-apps║
# ║                                                                  ║
# ║ Extracts compose.yaml from image, runs docker compose run.       ║
# ║ All mounts, network, env vars are declarative in compose.yaml.   ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

IMAGE="ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm:latest"
COMPOSE="/tmp/.cloud-builder-compose.yaml"

# ── Auto-detect GitHub token if not in env ─────────────────────────
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
  export GITHUB_TOKEN
fi

# ── Extract compose.yaml from image ───────────────────────────────
docker run --rm "$IMAGE" cat /opt/cloud-builder/compose.yaml > "$COMPOSE"

# ── Launch via docker compose ──────────────────────────────────────
exec docker compose -f "$COMPOSE" run --rm cloud-builder "$@"
