#!/bin/sh
# Cloudflare Worker build script
# Deploys email-forwarder Worker via wrangler CLI
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step 1: Build (copy src → dist) ────────────────────────────────────
step_build() {
    log "Copying src/ → dist/"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -r "$SRC_DIR/"* "$DIST_DIR/"
    log "Built files:"
    find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
}

# ── Step 2: Deploy via wrangler ─────────────────────────────────────────
step_deploy() {
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }
    if ! command -v wrangler >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
        log "ERROR: wrangler or npx not found. Install: npm install -g wrangler"
        return 1
    fi
    log "Deploying Worker to Cloudflare..."
    cd "$DIST_DIR"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler deploy
    else
        npx wrangler deploy
    fi
    log "Worker deployed"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Build: cloudflare-worker"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    build)   step_build ;;
    deploy)  step_deploy ;;
    ship)    step_build; step_deploy ;;
    all)     step_build ;;
    clean)   rm -rf "$DIST_DIR"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|deploy|ship|all|clean]"
        echo "  build   Copy src/ → dist/"
        echo "  deploy  Deploy Worker via wrangler"
        echo "  ship    build + deploy"
        echo "  all     build (default)"
        echo "  clean   Remove dist/"
        ;;
esac

log "Done."
