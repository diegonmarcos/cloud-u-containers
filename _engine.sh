#!/bin/sh
# Canonical build engine for all cloud services
# Symlinked as build.sh in each service directory
# All behavior driven by build.json — zero hardcoded service names
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR" | sed 's/^[a-z]*-[a-z]*_//')"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"

# ── Config reader (node primary, python3 fallback) ────────────────────
get_config() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v=$( echo "'$1'.split('.')" | sed "s/'/\"/g" ); r=c; exec('for k in v: r=r.get(k,{})'); print(r if isinstance(r,str) else '',end='')"
    fi
}

# JSON array reader → newline-separated values
get_config_array() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); if(Array.isArray(v)) v.forEach(i=>console.log(i))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json; c=json.load(open('$CONFIG'))
v = c
for k in '$1'.split('.'):
    v = v.get(k, {}) if isinstance(v, dict) else {}
if isinstance(v, list):
    for i in v: print(i)
"
    fi
}

# JSON object reader for lifecycle actions → JSON lines
get_lifecycle() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "
const c=require('$CONFIG');
const v=(c.lifecycle||{})['$1'];
if(Array.isArray(v)) v.forEach(a=>console.log(JSON.stringify(a)));
"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json; c=json.load(open('$CONFIG'))
for a in c.get('lifecycle',{}).get('$1',[]):
    print(json.dumps(a))
"
    fi
}

# ── Load config ───────────────────────────────────────────────────────
if [ -f "$CONFIG" ]; then
    DEPLOY_HOST="$(get_config deploy.host)"
    DEPLOY_PATH="$(get_config deploy.remote_path)"
    DOCKER_REGISTRY="$(get_config docker.registry)"
    DOCKER_IMAGE="$(get_config docker.image)"
    DOCKER_FILE="$(get_config docker.dockerfile)"
    DOCKER_BINARY="$(get_config docker.binary)"
    DOCKER_BINARY_NAME="$(get_config docker.binary_name)"
    SEQUENTIAL_RESTART="$(get_config deploy.sequential_restart)"
    COMPOSE_FLAGS="$(get_config deploy.compose_flags)"
    ESCAPE_DOLLARS="$(get_config secrets.escape_dollars)"
    JWKS_FILE="$(get_config secrets.jwks_file)"
    JWKS_DEST="$(get_config secrets.jwks_dest)"
    PRESERVE_SYMLINKS="$(get_config build.preserve_symlinks)"
    INCLUDE_CONFIG_JSON="$(get_config build.include_config_json)"
    COMPOSE_PRE_HOOK="$(get_config compose.pre_hook)"
    COMPOSE_POST_HOOK="$(get_config compose.post_hook)"
fi

# escape_dollars defaults to false — only enable in build.json for services that need it

# Binary name for deploy payload (default: SERVICE_NAME-binary)
: "${DOCKER_BINARY_NAME:=${SERVICE_NAME}-binary}"

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step: Docker image build ─────────────────────────────────────────
step_docker_remote() {
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"

    log "Syncing Docker context to $DEPLOY_HOST:$REMOTE_BUILD_DIR"
    ssh "$DEPLOY_HOST" "mkdir -p $REMOTE_BUILD_DIR"
    rsync -avz --delete "$SRC_DIR/" "$DEPLOY_HOST:$REMOTE_BUILD_DIR/"

    log "Building Docker image on $DEPLOY_HOST (remote)"
    ssh "$DEPLOY_HOST" "cd $REMOTE_BUILD_DIR && DOCKER_BUILDKIT=1 docker build -t $FULL_IMAGE:latest -f $DOCKERFILE ."

    ssh "$DEPLOY_HOST" "rm -rf $REMOTE_BUILD_DIR"
    log "Image built on $DEPLOY_HOST: $FULL_IMAGE:latest"
}

step_docker_local() {
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    SHA_TAG="${GITHUB_SHA:-$(git -C "$SERVICE_DIR" rev-parse HEAD 2>/dev/null || echo local)}"

    # Smart build: hash Dockerfile to skip rebuild when unchanged
    LOCAL_HASH=$(sha256sum "$SRC_DIR/$DOCKERFILE" 2>/dev/null | cut -c1-12)
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        REMOTE_HASH=$(ssh "$DEPLOY_HOST" "cat $DEPLOY_PATH/.dockerfile-hash 2>/dev/null" 2>/dev/null || true)
        if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
            log "Dockerfile unchanged (hash: $LOCAL_HASH) -- skipping Docker build"
            return 0
        fi
        [ -n "$REMOTE_HASH" ] && log "Dockerfile changed ($REMOTE_HASH -> $LOCAL_HASH)"
    fi

    log "Building Docker image: $FULL_IMAGE"

    docker buildx build \
        --push \
        --tag "$FULL_IMAGE:latest" \
        --tag "$FULL_IMAGE:$SHA_TAG" \
        --cache-from "type=registry,ref=$FULL_IMAGE:latest" \
        --cache-to "type=registry,ref=$FULL_IMAGE:buildcache,mode=max" \
        --file "$SRC_DIR/$DOCKERFILE" \
        "$SRC_DIR/"

    log "Pushed $FULL_IMAGE:latest + :$SHA_TAG"

    # Save hash to temp (step_build wipes dist/, so persist outside it)
    echo "$LOCAL_HASH" > "$SERVICE_DIR/.dockerfile-hash-new"

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

step_docker() {
    [ -z "$DOCKER_IMAGE" ] && { log "No docker.image in build.json -- skipping"; return 0; }

    if [ "${REMOTE_BUILD:-}" = "true" ]; then
        step_docker_remote
    else
        step_docker_local
    fi
}

# ── Step: Build nix flake ────────────────────────────────────────────
step_build() {
    log "Building nix flake -> dist/"
    cd "$SRC_DIR"

    nix build --out-link "$SERVICE_DIR/.result"

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    # Preserve symlinks (mailu) vs dereference (default)
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        cp -ra "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    else
        cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    fi
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    # Carry over dockerfile hash from step_docker (if image was rebuilt)
    if [ -f "$SERVICE_DIR/.dockerfile-hash-new" ]; then
        mv "$SERVICE_DIR/.dockerfile-hash-new" "$DIST_DIR/.dockerfile-hash"
    fi

    # Include shared config.json for dynamic VM/service discovery
    if [ "$INCLUDE_CONFIG_JSON" = "true" ]; then
        CONFIG_JSON="$SERVICE_DIR/../config.json"
        if [ -f "$CONFIG_JSON" ]; then
            cp "$CONFIG_JSON" "$DIST_DIR/config.json"
            log "Included config.json in dist/"
        fi
    fi

    # Copy extra source files for on-VM builds (e.g. Rust source for rig)
    EXTRA_COPY="$(get_config_array build.extra_copy)"
    if [ -n "$EXTRA_COPY" ]; then
        echo "$EXTRA_COPY" | while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            # Handle directories (ending with /)
            if [ -d "$SRC_DIR/$pattern" ]; then
                cp -r "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            elif [ -f "$SRC_DIR/$pattern" ]; then
                cp "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            fi
            log "Copied extra: $pattern"
        done
    fi

    log "Built files:"
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        find "$DIST_DIR" -type f -o -type l | sed "s|$DIST_DIR/|  |"
    else
        find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
    fi
}

# ── Step: Build documentation ────────────────────────────────────────
step_docs() {
    log "Building documentation..."
    cd "$SRC_DIR"

    nix build .#docs --out-link "$SERVICE_DIR/.result-docs"

    mkdir -p "$DIST_DIR/docs"
    cp -rL "$SERVICE_DIR/.result-docs/"* "$DIST_DIR/docs/"
    chmod -R u+w "$DIST_DIR/docs"
    rm -f "$SERVICE_DIR/.result-docs"

    log "Documentation built -> dist/docs/"
}

# ── Step: Decrypt secrets ────────────────────────────────────────────
step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml -- skipping"
        return 0
    fi

    log "Decrypting secrets -> dist/.secrets"
    mkdir -p "$DIST_DIR"

    # JWKS filtering: exclude multi-line PEM key from env file
    if [ -n "$JWKS_FILE" ]; then
        if command -v yq >/dev/null 2>&1; then
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
            log "ERROR: No yq or python3 for YAML->env conversion"
            return 1
        fi
    else
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
            log "ERROR: No yq or python3 for YAML->env conversion"
            return 1
        fi
    fi

    # Escape $ as $$ for docker-compose env_file interpolation
    if [ "$ESCAPE_DOLLARS" = "true" ]; then
        sed -i 's/[$]/&&/g' "$DIST_DIR/.secrets"
    fi

    # Extract JWKS key as PEM file (multi-line value can't go in env_file)
    if [ -n "$JWKS_FILE" ] && [ -f "$SRC_DIR/$JWKS_FILE" ]; then
        JWKS_DEST_PATH="${JWKS_DEST:-config/oidc_jwks.pem}"
        mkdir -p "$DIST_DIR/$(dirname "$JWKS_DEST_PATH")"
        sops -d --extract '["key"]' "$SRC_DIR/$JWKS_FILE" > "$DIST_DIR/$JWKS_DEST_PATH"
        chmod 600 "$DIST_DIR/$JWKS_DEST_PATH"
        log "JWKS key -> $JWKS_DEST_PATH"
    fi

    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.secrets" 2>/dev/null || echo 0) keys)"
}

# ── Step: Deploy dist/ to VM via rsync ───────────────────────────────
step_deploy() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping deploy"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    # Include binary + runtime Dockerfile for local image build on VM
    BINARY_PATH="/tmp/${SERVICE_NAME}-binary"
    RUNTIME_DF="$SRC_DIR/Dockerfile.runtime"
    if [ -f "$BINARY_PATH" ] && [ -f "$RUNTIME_DF" ]; then
        cp "$BINARY_PATH" "$DIST_DIR/$DOCKER_BINARY_NAME"
        cp "$RUNTIME_DF" "$DIST_DIR/Dockerfile.runtime"
        log "Included binary + Dockerfile.runtime in deploy payload"
    fi

    log "Deploying dist/ -> $DEPLOY_HOST:$DEPLOY_PATH"

    # Ensure remote dir exists
    ssh "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"

    # Build rsync exclude flags from build.json array
    RSYNC_EXCLUDES=""
    EXCLUDES="$(get_config_array deploy.excludes)"
    if [ -n "$EXCLUDES" ]; then
        RSYNC_EXCLUDES=$(echo "$EXCLUDES" | while IFS= read -r ex; do
            [ -n "$ex" ] && printf " --exclude '%s'" "$ex"
        done)
    fi

    # Sync (rsync primary, rclone fallback)
    if command -v rsync >/dev/null 2>&1; then
        eval rsync -avz --delete $RSYNC_EXCLUDES '"$DIST_DIR/"' '"$DEPLOY_HOST:$DEPLOY_PATH/"'
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

# ── Step: Docker compose on VM ───────────────────────────────────────
step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"

    # Image strategy: binary transfer > already local > registry pull
    if [ -n "$DOCKER_BINARY" ] && ssh "$DEPLOY_HOST" "test -f $DEPLOY_PATH/$DOCKER_BINARY_NAME -a -f $DEPLOY_PATH/Dockerfile.runtime" 2>/dev/null; then
        log "Building image locally on $DEPLOY_HOST (from pre-compiled binary)"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker build -q -t $FULL_IMAGE:latest -f Dockerfile.runtime ."
        log "Image built locally"
    elif [ -n "$FULL_IMAGE" ] && ssh "$DEPLOY_HOST" "docker image inspect $FULL_IMAGE:latest >/dev/null 2>&1" 2>/dev/null; then
        log "Image already local -- config-only restart"
    elif [ -n "$FULL_IMAGE" ]; then
        log "No local image -- falling back to docker compose pull"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose pull --ignore-buildable"
    fi

    # Pre-compose hook (e.g. mailu init.sh)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        log "Running pre-compose hook: $COMPOSE_PRE_HOOK"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK"
    fi

    ENV_FILE_FLAG="\$([ -f .secrets ] && echo '--env-file .secrets')"

    if [ "$SEQUENTIAL_RESTART" = "true" ]; then
        # Sequential restart: stop -> settle -> start (avoids CPU spike on low-resource VMs)
        log "Stopping containers on $DEPLOY_HOST"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose stop" || true
        log "Waiting for CPU to settle..."
        sleep 5
        log "Starting containers on $DEPLOY_HOST:$DEPLOY_PATH"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose $ENV_FILE_FLAG up -d"
    else
        # Standard: down + up with force-recreate
        EXTRA_FLAGS="${COMPOSE_FLAGS:-}"
        log "Rebuilding $SERVICE_NAME on $DEPLOY_HOST:$DEPLOY_PATH"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose down --remove-orphans 2>/dev/null; docker compose $ENV_FILE_FLAG up -d --force-recreate $EXTRA_FLAGS"
    fi

    # Post-compose hook (e.g. mailu setup.sh)
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        log "Running post-compose hook: $COMPOSE_POST_HOOK"
        ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_POST_HOOK && ./$COMPOSE_POST_HOOK"
    fi

    log "Container rebuilt and running"
}

# ── Lifecycle commands (driven by build.json) ────────────────────────
run_lifecycle() {
    COMMAND="$1"
    ACTIONS="$(get_lifecycle "$COMMAND")"

    if [ -z "$ACTIONS" ]; then
        log "No lifecycle.$COMMAND defined in build.json"
        return 1
    fi

    log "Running lifecycle: $COMMAND"
    echo "$ACTIONS" | while IFS= read -r action_json; do
        [ -z "$action_json" ] && continue

        ACTION="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).action||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''),end='')")"
        VM="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).vm||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vm',''),end='')")"
        CONTAINER="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).container||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('container',''),end='')")"
        COMPOSE_PATH="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).path||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path',''),end='')")"
        SCRIPT="$(echo "$action_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).script||'')" 2>/dev/null || echo "$action_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('script',''),end='')")"

        : "${VM:=$DEPLOY_HOST}"

        case "$ACTION" in
            compose_stop)
                log "  Stopping compose at $VM:$COMPOSE_PATH"
                ssh "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml stop" || true
                ;;
            compose_start)
                log "  Starting compose at $VM:$COMPOSE_PATH"
                ssh "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml start"
                ;;
            exec)
                log "  Exec in $CONTAINER on $VM: $SCRIPT"
                ssh "$VM" "docker exec $CONTAINER $SCRIPT" || true
                ;;
            stats)
                ssh "$VM" "free -h && echo '---' && docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'"
                ;;
        esac
    done

    log "Lifecycle $COMMAND complete"
}

# ── Main ─────────────────────────────────────────────────────────────
echo "========================================"
echo "  Build: $SERVICE_NAME"
echo "========================================"

case "${1:-all}" in
    docker)   step_docker ;;
    build)    step_build ;;
    docs)     step_docs ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    all)      step_build; step_docs; step_secrets ;;
    ship)     step_docker; step_build; step_secrets; step_deploy; step_compose ;;
    redeploy) step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result" "$SERVICE_DIR/.result-docs"; log "Cleaned" ;;
    *)
        # Try lifecycle command from build.json
        if [ -f "$CONFIG" ] && get_lifecycle "$1" | grep -q .; then
            run_lifecycle "$1"
        else
            echo "Usage: $0 [docker|build|docs|secrets|deploy|compose|all|ship|redeploy|clean|<lifecycle>]"
            echo "  docker    Build + push Docker image"
            echo "  build     Build nix flake -> dist/"
            echo "  docs      Build documentation -> dist/docs/"
            echo "  secrets   Decrypt secrets -> dist/.secrets"
            echo "  deploy    Rsync dist/ -> VM"
            echo "  compose   Docker compose up on VM"
            echo "  all       build + docs + secrets (default)"
            echo "  ship      docker + build + secrets + deploy + compose"
            echo "  redeploy  build + secrets + deploy + compose (skip docker)"
            echo "  clean     Remove dist/"
            # Show available lifecycle commands
            if [ -f "$CONFIG" ]; then
                LIFECYCLE_CMDS="$(node -e "const c=require('$CONFIG'); Object.keys(c.lifecycle||{}).forEach(k=>console.log('  '+k))" 2>/dev/null || python3 -c "import json; [print('  '+k) for k in json.load(open('$CONFIG')).get('lifecycle',{})]" 2>/dev/null)"
                if [ -n "$LIFECYCLE_CMDS" ]; then
                    echo ""
                    echo "Lifecycle commands:"
                    echo "$LIFECYCLE_CMDS"
                fi
            fi
        fi
        ;;
esac

log "Done."
