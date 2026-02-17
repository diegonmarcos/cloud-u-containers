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

DOCKER_REGISTRY="$(get_config docker.registry)"
DOCKER_IMAGE="$(get_config docker.image)"
DOCKER_FILE="$(get_config docker.dockerfile)"
DOCKER_BINARY="$(get_config docker.binary)"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step 0: Build and push Docker image ──────────────────────────────
step_docker() {
    [ -z "$DOCKER_IMAGE" ] && { log "No docker.image in build.json — skipping"; return 0; }

    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    SHA_TAG="${GITHUB_SHA:-$(git -C "$SERVICE_DIR" rev-parse HEAD 2>/dev/null || echo local)}"

    log "Building Docker image: $FULL_IMAGE"

    docker buildx build \
        --push \
        --tag "$FULL_IMAGE:latest" \
        --tag "$FULL_IMAGE:$SHA_TAG" \
        --cache-from "type=registry,ref=$FULL_IMAGE:latest" \
        --file "$SRC_DIR/$DOCKERFILE" \
        "$SRC_DIR/"

    log "Pushed $FULL_IMAGE:latest + :$SHA_TAG"

    # Extract binary for direct transfer (avoids image pull/decompression on VM)
    if [ -n "$DOCKER_BINARY" ]; then
        log "Extracting binary from image"
        docker pull "$FULL_IMAGE:latest"
        CONTAINER_ID=$(docker create "$FULL_IMAGE:latest")
        docker cp "$CONTAINER_ID:$DOCKER_BINARY" "/tmp/${SERVICE_NAME}-binary"
        docker rm "$CONTAINER_ID"
        log "Extracted binary ($(du -h "/tmp/${SERVICE_NAME}-binary" | cut -f1))"
    fi
}

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

    # Escape $ as $$ for docker-compose env_file interpolation
    sed -i 's/[$]/&&/g' "$DIST_DIR/.secrets"

    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.secrets" 2>/dev/null || echo 0) keys)"
}

# ── Step 3: Deploy dist/ → VM via rsync ────────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "ERROR: deploy.host not set in build.json"; return 1; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — run build first"; return 1; }

    # Include binary + runtime Dockerfile for local image build on VM
    BINARY_PATH="/tmp/${SERVICE_NAME}-binary"
    RUNTIME_DF="$SRC_DIR/Dockerfile.runtime"
    if [ -f "$BINARY_PATH" ] && [ -f "$RUNTIME_DF" ]; then
        cp "$BINARY_PATH" "$DIST_DIR/rust-api-binary"
        cp "$RUNTIME_DF" "$DIST_DIR/Dockerfile.runtime"
        log "Included binary + Dockerfile.runtime in deploy payload"
    fi

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

    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"

    # Image strategy: binary transfer > already local > registry pull
    if ssh "$DEPLOY_HOST" "test -f $DEPLOY_PATH/rust-api-binary -a -f $DEPLOY_PATH/Dockerfile.runtime" 2>/dev/null; then
        log "Building image locally on $DEPLOY_HOST (from pre-compiled binary)"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker build -q -t $FULL_IMAGE:latest -f Dockerfile.runtime ."
        log "Image built locally"
    elif [ -n "$FULL_IMAGE" ] && ssh "$DEPLOY_HOST" "docker image inspect $FULL_IMAGE:latest >/dev/null 2>&1" 2>/dev/null; then
        log "Image already local — config-only restart"
    elif [ -n "$FULL_IMAGE" ]; then
        log "No local image — falling back to docker compose pull"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose pull --ignore-buildable"
    fi

    # Sequential restart: stop → settle → start (avoids CPU spike on low-resource VMs)
    log "Stopping containers on $DEPLOY_HOST"
    ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose stop" || true

    log "Waiting for CPU to settle..."
    sleep 5

    log "Starting containers on $DEPLOY_HOST:$DEPLOY_PATH"
    ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose \$([ -f .secrets ] && echo '--env-file .secrets') up -d"
    log "Containers running"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Build: $SERVICE_NAME"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    docker)   step_docker ;;
    build)    step_build ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    all)      step_build; step_secrets ;;
    ship)     step_docker; step_build; step_secrets; step_deploy; step_compose ;;
    redeploy) step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [docker|build|secrets|deploy|compose|all|ship|clean]"
        echo "  docker   Build + push Docker image"
        echo "  build    Build nix flake → dist/"
        echo "  secrets  Decrypt secrets → dist/.secrets"
        echo "  deploy   Rsync dist/ → VM"
        echo "  compose  Docker compose pull + up on VM"
        echo "  all      build + secrets (default)"
        echo "  ship     docker + build + secrets + deploy + compose"
        echo "  redeploy build + secrets + deploy + compose (skip docker)"
        echo "  clean    Remove dist/"
        ;;
esac

log "Done."
