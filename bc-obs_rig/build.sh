#!/bin/sh
# Per-service build script: src/ → dist/ → VM
# Rig: builds on-VM via Docker (aarch64) — no GHCR push
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR" | sed 's/^[a-z]*-[a-z]*_//')"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"

# Deploy config from build.json (node primary, python3 fallback)
get_config() {
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v=$( echo "'$1'.split('.')" | sed "s/'/\"/g" ); r=c; exec('for k in v: r=r.get(k,{})'); print(r if isinstance(r,str) else '',end='')"
    fi
}

DEPLOY_HOST="$(get_config deploy.host)"
DEPLOY_PATH="$(get_config deploy.remote_path)"

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step 1: Build nix flake + copy Rust source ──────────────────────────
step_build() {
    log "Building nix flake → dist/"
    cd "$SRC_DIR"

    nix build --out-link "$SERVICE_DIR/.result"

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    # Copy Rust source for on-VM Docker build
    log "Copying Rust source → dist/"
    cp "$SRC_DIR/Cargo.toml" "$DIST_DIR/"
    [ -f "$SRC_DIR/Cargo.lock" ] && cp "$SRC_DIR/Cargo.lock" "$DIST_DIR/"
    cp "$SRC_DIR/Dockerfile" "$DIST_DIR/"
    cp -r "$SRC_DIR/src" "$DIST_DIR/src"

    log "Built files:"
    find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
}


# ── Step 1b: Build documentation ─────────────────────────────────────────
step_docs() {
    log "Building documentation..."
    cd "$SRC_DIR"

    nix build .#docs --out-link "$SERVICE_DIR/.result-docs"

    mkdir -p "$DIST_DIR/docs"
    cp -rL "$SERVICE_DIR/.result-docs/"* "$DIST_DIR/docs/"
    chmod -R u+w "$DIST_DIR/docs"
    rm -f "$SERVICE_DIR/.result-docs"

    log "Documentation built → dist/docs/"
}


# ── Step 2: Decrypt secrets → .secrets ───────────────────────────────────
step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml — skipping"
        return 0
    fi

    log "Decrypting secrets → dist/.secrets"
    mkdir -p "$DIST_DIR"

    if command -v yq >/dev/null 2>&1; then
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$DIST_DIR/.secrets"
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
            print(f'{k}={v}')
" > "$DIST_DIR/.secrets"
    else
        log "ERROR: No yq or python3 for YAML→env conversion"
        return 1
    fi

    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.secrets" 2>/dev/null || echo 0) keys)"
}

# ── Step 3: Deploy dist/ → VM via rsync ─────────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "ERROR: deploy.host not set in build.json"; return 1; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    log "Deploying dist/ → $DEPLOY_HOST:$DEPLOY_PATH"

    # Ensure remote dir exists
    ssh "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"

    # Sync — exclude .secrets (created on VM, not in dist/)
    if command -v rsync >/dev/null 2>&1; then
        rsync -avz --delete --exclude='.secrets' "$DIST_DIR/" "$DEPLOY_HOST:$DEPLOY_PATH/"
    elif command -v rclone >/dev/null 2>&1; then
        rclone sync "$DIST_DIR/" ":sftp:$DEPLOY_PATH/" \
            --sftp-host="$(ssh -G "$DEPLOY_HOST" | grep '^hostname ' | awk '{print $2}')" \
            --sftp-user="$(ssh -G "$DEPLOY_HOST" | grep '^user ' | awk '{print $2}')" \
            --sftp-key-file="$(ssh -G "$DEPLOY_HOST" | grep '^identityfile ' | head -1 | awk '{print $2}')" \
            --transfers=4
    else
        log "ERROR: No rsync or rclone available"
        return 1
    fi

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"
}

# ── Step 4: Docker build + compose on VM (aarch64, on-machine) ───────────
step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "ERROR: deploy.host not set in build.json"; return 1; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    log "Building Docker image + starting containers on $DEPLOY_HOST"
    ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose down --remove-orphans 2>/dev/null; docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d --build"
    log "Container built and running on $DEPLOY_HOST"
}

# ── Main ─────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Build: $SERVICE_NAME"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    build)    step_build ;;
    docs)     step_docs ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    all)      step_build; step_docs; step_secrets ;;
    ship)     step_build; step_docs; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result" "$SERVICE_DIR/.result-docs"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|docs|secrets|deploy|compose|all|ship|clean]"
        echo "  build    Build nix flake + copy Rust source → dist/"
        echo "  secrets  Decrypt secrets → dist/.secrets"
        echo "  deploy   Rsync dist/ → VM"
        echo "  compose  Docker build + compose up on VM (aarch64)"
        echo "  all      build + docs + secrets (default)"
        echo "  ship     build + docs + secrets + deploy + compose"
        echo "  clean    Remove dist/"
        ;;
esac

log "Done."
