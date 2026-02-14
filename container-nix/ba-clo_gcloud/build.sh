#\!/bin/sh
# Per-service build script: src/ → dist/
# Builds nix flake, decrypts secrets, outputs everything to dist/
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR" | sed 's/^[a-z]*-[a-z]*_//')"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step 1: Build nix flake ────────────────────────────────────────────
step_build() {
    log "Building nix flake → dist/"
    cd "$SRC_DIR"

    nix build --out-link "$SERVICE_DIR/.result"

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    log "Built files:"
    find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
}

# ── Step 2: Decrypt secrets → .secrets ─────────────────────────────────────
step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ \! -f "$secrets_file" ]; then
        log "No secrets.yaml — skipping"
        return 0
    fi

    log "Decrypting secrets → dist/.secrets"
    mkdir -p "$DIST_DIR"

    if command -v yq >/dev/null 2>&1; then
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)='"'"'\(.value)'"'"'"' > "$DIST_DIR/.secrets"
    elif command -v python3 >/dev/null 2>&1; then
        sops -d "$secrets_file" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('sops:'):
        break
    if not line or line.startswith('#'):
        continue
    if ':' in line:
        k, v = line.split(':', 1)
        k, v = k.strip(), v.strip().strip('\"').strip(\"'\")
        if v:
            print(f"{k}='{v}'")
" > "$DIST_DIR/.secrets"
    else
        log "ERROR: No yq or python3 for YAML→env conversion"
        return 1
    fi


    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.secrets" 2>/dev/null || echo 0) keys)"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Build: $SERVICE_NAME"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    build)    step_build ;;
    secrets)  step_secrets ;;
    all)      step_build; step_secrets ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|all|clean]"
        echo "  build    Build nix flake → dist/"
        echo "  secrets  Decrypt secrets → dist/.secrets"
        echo "  all      Both (default)"
        echo "  clean    Remove dist/"
        ;;
esac

log "Done."
