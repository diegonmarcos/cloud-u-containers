#!/bin/sh
# Cloud Documentation Portal - build script
# Collects per-service docs and builds a unified mdBook site
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="cloud-spec"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
SOLUTIONS_DIR="$(dirname "$SERVICE_DIR")"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Build portal mdBook ──────────────────────────────────────────────────
step_portal() {
    log "Building portal mdBook..."
    cd "$SRC_DIR"
    nix build --out-link "$SERVICE_DIR/.result-portal"

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SERVICE_DIR/.result-portal/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result-portal"

    log "Portal built → dist/"
}

# ── Build all service docs ───────────────────────────────────────────────
step_services() {
    log "Building service documentation..."
    mkdir -p "$DIST_DIR/services"

    for svc_dir in "$SOLUTIONS_DIR"/*/; do
        name=$(basename "$svc_dir")
        flake="$svc_dir/src"

        # Skip non-flake services and ourselves
        [ -f "$flake/flake.nix" ] || continue
        [ "$name" = "cloud-spec" ] && continue

        # Check if flake has a docs output
        if ! nix eval "$flake#packages.aarch64-linux.docs" --apply 'x: true' 2>/dev/null; then
            if ! nix eval "$flake#packages.x86_64-linux.docs" --apply 'x: true' 2>/dev/null; then
                log "  SKIP $name (no docs output)"
                continue
            fi
        fi

        log "  Building $name..."
        if nix build "$flake#docs" --out-link "$SERVICE_DIR/.result-$name" 2>/dev/null; then
            mkdir -p "$DIST_DIR/services/$name"
            cp -rL "$SERVICE_DIR/.result-$name/"* "$DIST_DIR/services/$name/"
            chmod -R u+w "$DIST_DIR/services/$name"
            rm -f "$SERVICE_DIR/.result-$name"
        else
            log "  WARN: Failed to build docs for $name"
        fi
    done

    log "Service docs collected → dist/services/"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Build: $SERVICE_NAME"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    portal)   step_portal ;;
    services) step_services ;;
    all)      step_portal; step_services ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR"/.result-*; log "Cleaned" ;;
    *)
        echo "Usage: $0 [portal|services|all|clean]"
        echo "  portal    Build portal overview pages"
        echo "  services  Build + collect all service docs"
        echo "  all       portal + services (default)"
        echo "  clean     Remove dist/"
        ;;
esac

log "Done."
