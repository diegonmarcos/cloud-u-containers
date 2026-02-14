#!/bin/sh
# Per-service build script: src/ → dist/ → VM
# Builds nix flake, decrypts secrets, deploys via rsync, runs docker compose
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
        # Convert YAML to KEY=VALUE, keep only single-line entries (excludes multi-line JWKS PEM)
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)=\(.value)"' \
            | grep '^[A-Z_]*=' | grep -v '^AUTHELIA_OIDC_JWKS_KEY=' > "$DIST_DIR/.secrets"
    elif command -v python3 >/dev/null 2>&1; then
        sops -d "$secrets_file" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin)
for k, v in data.items():
    if k == 'sops' or k == 'AUTHELIA_OIDC_JWKS_KEY':
        continue
    if isinstance(v, str):
        print(f'{k}={v}')
" > "$DIST_DIR/.secrets"
    else
        log "ERROR: No yq or python3 for YAML→env conversion"
        return 1
    fi

    # Escape $ as $$ for docker-compose env_file interpolation
    sed -i 's/[$]/&&/g' "$DIST_DIR/.secrets"

    # Extract JWKS key as PEM file (multi-line value can't go in env_file)
    jwks_file="$SRC_DIR/jwks_key.yaml"
    if [ -f "$jwks_file" ]; then
        mkdir -p "$DIST_DIR/config"
        sops -d --extract '["key"]' "$jwks_file" > "$DIST_DIR/config/oidc_jwks.pem"
        chmod 600 "$DIST_DIR/config/oidc_jwks.pem"
        log "JWKS key → config/oidc_jwks.pem"
    fi

    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.secrets" 2>/dev/null || echo 0) keys)"
}

# ── Step 3: Deploy dist/ → VM via rsync ────────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "ERROR: deploy.host not set in build.json"; return 1; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    log "Deploying dist/ → $DEPLOY_HOST:$DEPLOY_PATH"

    # Ensure remote dir exists
    ssh "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"

    # Sync (rsync primary, rclone fallback)
    if command -v rsync >/dev/null 2>&1; then
        rsync -avz --delete "$DIST_DIR/" "$DEPLOY_HOST:$DEPLOY_PATH/"
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

# ── Step 4: Docker compose rebuild on VM ───────────────────────────────
step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "ERROR: deploy.host not set in build.json"; return 1; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    log "Rebuilding $SERVICE_NAME on $DEPLOY_HOST:$DEPLOY_PATH"
    ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose down --remove-orphans 2>/dev/null; docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d --force-recreate --no-deps $SERVICE_NAME"
    log "Container rebuilt and running"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Build: $SERVICE_NAME"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    build)    step_build ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    all)      step_build; step_secrets ;;
    ship)     step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|deploy|compose|all|ship|clean]"
        echo "  build    Build nix flake → dist/"
        echo "  secrets  Decrypt secrets → dist/.secrets"
        echo "  deploy   Rsync dist/ → VM"
        echo "  compose  Docker compose up --build on VM"
        echo "  all      build + secrets (default)"
        echo "  ship     build + secrets + deploy + compose"
        echo "  clean    Remove dist/"
        ;;
esac

log "Done."
