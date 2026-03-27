#!/bin/sh
# Canonical build engine for all cloud services
# Symlinked as build.sh in each service directory
# All behavior driven by build.json — zero hardcoded service names
set -e

# Auto-confirm guardrail prompts (BLOCKED tier is never bypassed)
export BUILDSH_GUARDRAIL=1

# Shared node_modules — ESM resolution needs NODE_PATH
export NODE_PATH="${NODE_PATH:-$HOME/.node_modules/node_modules}"

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
    DOCKER_PLATFORM="$(get_config docker.platform)"
    SEQUENTIAL_RESTART="$(get_config deploy.sequential_restart)"
    COMPOSE_FLAGS="$(get_config deploy.compose_flags)"
    ESCAPE_DOLLARS="$(get_config secrets.escape_dollars)"
    JWKS_FILE="$(get_config secrets.jwks_file)"
    JWKS_DEST="$(get_config secrets.jwks_dest)"
    PRESERVE_SYMLINKS="$(get_config build.preserve_symlinks)"
    INCLUDE_CLOUD_DATA="$(get_config build.include_cloud_data)"
    COMPOSE_PRE_HOOK="$(get_config compose.pre_hook)"
    COMPOSE_POST_HOOK="$(get_config compose.post_hook)"
    WRANGLER_DEPLOY="$(get_config deploy.wrangler)"
    TERRAFORM_DEPLOY="$(get_config deploy.terraform)"
    TERRAFORM_TFVARS_TEMPLATE="$(get_config terraform.tfvars_template)"
    BUILD_COPY_ONLY="$(get_config build.copy_only)"
fi

# ── Profile system: CLOUD_PROFILE selects active topology ────────────
if [ -n "${CLOUD_PROFILE:-}" ]; then
    PROFILE_JSON="$SERVICE_DIR/../../build_${CLOUD_PROFILE}.json"
    if [ -f "$PROFILE_JSON" ]; then
        P_HOST=$(node -e "const f=require('$PROFILE_JSON');const s=(f.services||{})['$SERVICE_NAME'];process.stdout.write(s&&s.deploy&&s.deploy.host||'')")
        if [ -n "$P_HOST" ]; then
            DEPLOY_HOST="$P_HOST"
            FORCE_DEPLOY=1
        else
            log "PROFILE[$CLOUD_PROFILE]: $SERVICE_NAME not in profile — skipping"
            exit 0
        fi
    fi
fi

# SSH multiplexing: one connection reused across all steps, kept alive 120s
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-mux-%r@%h:%p -o ControlPersist=120 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"


# escape_dollars defaults to false — only enable in build.json for services that need it

# Binary name for deploy payload (default: SERVICE_NAME-binary)
: "${DOCKER_BINARY_NAME:=${SERVICE_NAME}-binary}"

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
log_warn() { printf "\033[0;33m[%s] WARNING: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1"; }
log_error() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1"; }

# Global error handler: print step name on failure
CURRENT_STEP=""
DOCKER_IMAGE_CHANGED=""
trap 'if [ -n "$CURRENT_STEP" ]; then log_error "Step '\''$CURRENT_STEP'\'' failed (exit $?)"; fi' EXIT

# ── Step: Docker image build ─────────────────────────────────────────
step_docker_remote() {
    CURRENT_STEP="docker-remote"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"

    # Smart build: hash src/ to skip rebuild when unchanged
    LOCAL_HASH=$(find "$SRC_DIR" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -not -name 'secrets.yaml' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        REMOTE_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat $DEPLOY_PATH/.docker-src-hash 2>/dev/null" 2>/dev/null || true)
        if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
            log "Docker src unchanged (hash: $LOCAL_HASH) -- skipping remote Docker build"
            return 0
        fi
        [ -n "$REMOTE_HASH" ] && log "Docker src changed ($REMOTE_HASH -> $LOCAL_HASH)"
    fi

    log "Syncing Docker context to $DEPLOY_HOST:$REMOTE_BUILD_DIR"
    ssh $SSH_OPTS "$DEPLOY_HOST" "mkdir -p $REMOTE_BUILD_DIR"
    rsync -avzL --delete "$SRC_DIR/" "$DEPLOY_HOST:$REMOTE_BUILD_DIR/"

    log "Building Docker image on $DEPLOY_HOST (remote, verbose)"
    log "── Dockerfile: $DOCKERFILE ──"
    ssh $SSH_OPTS "$DEPLOY_HOST" "cat $REMOTE_BUILD_DIR/$DOCKERFILE" 2>/dev/null || true
    log "── docker build (verbose) ──"
    ssh $SSH_OPTS "$DEPLOY_HOST" "cd $REMOTE_BUILD_DIR && DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain docker build --progress=plain -t $FULL_IMAGE:latest -f $DOCKERFILE . 2>&1" | while IFS= read -r line; do printf "[docker-remote] %s\n" "$line"; done

    ssh $SSH_OPTS "$DEPLOY_HOST" "rm -rf $REMOTE_BUILD_DIR"
    log "Image built on $DEPLOY_HOST: $FULL_IMAGE:latest"
    echo "$LOCAL_HASH" > "$SERVICE_DIR/.docker-src-hash-new"
    DOCKER_IMAGE_CHANGED=true
}

step_docker_local() {
    CURRENT_STEP="docker-local"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    SHA_TAG="${GITHUB_SHA:-$(git -C "$SERVICE_DIR" rev-parse HEAD 2>/dev/null || echo local)}"

    # Smart build: hash entire src/ (Dockerfile + source code) to skip rebuild when unchanged
    LOCAL_HASH=$(find "$SRC_DIR" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -not -name 'secrets.yaml' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        REMOTE_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat $DEPLOY_PATH/.docker-src-hash 2>/dev/null" 2>/dev/null || true)
        if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
            log "Docker src unchanged (hash: $LOCAL_HASH) -- skipping Docker build"
            return 0
        fi
        [ -n "$REMOTE_HASH" ] && log "Docker src changed ($REMOTE_HASH -> $LOCAL_HASH)"
    fi

    # Platform: explicit override from build.json or auto-detect from deploy host
    PLATFORM_FLAG=""
    if [ -n "$DOCKER_PLATFORM" ]; then
        PLATFORM_FLAG="--platform=$DOCKER_PLATFORM"
        log "Explicit platform: $DOCKER_PLATFORM (from build.json docker.platform)"
    else
        case "$DEPLOY_HOST" in
            oci-apps|oci-apps-1|oci-apps-2)
                PLATFORM_FLAG="--platform=linux/amd64,linux/arm64"
                log "ARM host ($DEPLOY_HOST) — multi-arch build"
                ;;
        esac
    fi
    if echo "$PLATFORM_FLAG" | grep -q ','; then
        docker buildx inspect multiarch >/dev/null 2>&1 || \
            docker buildx create --name multiarch --use >/dev/null 2>&1
        docker buildx use multiarch 2>/dev/null
    fi

    # Use dist/ as build context if it exists (nix-generated files live there)
    # Fall back to src/ for services that don't use nix build
    BUILD_CONTEXT="$SRC_DIR"
    if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/$DOCKERFILE" ]; then
        BUILD_CONTEXT="$DIST_DIR"
    elif [ -d "$DIST_DIR" ]; then
        BUILD_CONTEXT="$DIST_DIR"
    fi

    # Dockerfile path must be inside build context for buildx container driver
    DOCKERFILE_PATH="$SRC_DIR/$DOCKERFILE"
    [ "$BUILD_CONTEXT" = "$DIST_DIR" ] && [ -f "$DIST_DIR/$DOCKERFILE" ] && DOCKERFILE_PATH="$DIST_DIR/$DOCKERFILE"

    log "Building Docker image: $FULL_IMAGE ${PLATFORM_FLAG:+(multi-arch)} (verbose)"
    log "── Dockerfile: $DOCKERFILE_PATH (context: $BUILD_CONTEXT) ──"
    cat "$DOCKERFILE_PATH" 2>/dev/null || true
    log "── docker buildx build --push (verbose) ──"

    BUILDKIT_PROGRESS=plain docker buildx build \
        --progress=plain \
        --push \
        $PLATFORM_FLAG \
        --tag "$FULL_IMAGE:latest" \
        --tag "$FULL_IMAGE:$SHA_TAG" \
        --cache-from "type=registry,ref=$FULL_IMAGE:latest" \
        --cache-to "type=registry,ref=$FULL_IMAGE:buildcache,mode=max" \
        --file "$DOCKERFILE_PATH" \
        "$BUILD_CONTEXT/" 2>&1 | while IFS= read -r line; do printf "[docker-local] %s\n" "$line"; done

    log "Pushed $FULL_IMAGE:latest + :$SHA_TAG"

    # Ensure GHCR package is public (CRITICAL — private packages are forbidden)
    PKG_NAME=$(echo "$FULL_IMAGE" | awk -F/ '{print $NF}')
    if command -v gh >/dev/null 2>&1; then
        PKG_VIS=$(gh api "/user/packages/container/${PKG_NAME}" --jq '.visibility' 2>/dev/null || echo "unknown")
        if [ "$PKG_VIS" = "private" ]; then
            log_warn "GHCR package '$PKG_NAME' is PRIVATE — attempting to fix via repo link"
            # Delete and let GHA re-push (GHA push = auto-public)
            log_warn "Package will become public on next GHA ship. Triggering workflow..."
            gh workflow run "Ship → CI image" --repo "${GITHUB_REPOSITORY:-diegonmarcos/cloud}" 2>/dev/null || true
            log_error "PRIVATE PACKAGE DETECTED: $PKG_NAME — push from GHA to make public"
        elif [ "$PKG_VIS" = "public" ]; then
            log "Package $PKG_NAME: public ✓"
        fi
    fi

    # Save hash to temp (step_build wipes dist/, so persist outside it)
    echo "$LOCAL_HASH" > "$SERVICE_DIR/.docker-src-hash-new"
    DOCKER_IMAGE_CHANGED=true

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

    # All builds happen locally (GHA runner / desktop) with buildx multi-arch.
    # ARM VMs (oci-apps) get --platform linux/amd64,linux/arm64.
    # REMOTE_BUILD=true is legacy — only use if explicitly forced.
    if [ "${REMOTE_BUILD:-}" = "true" ]; then
        log "REMOTE_BUILD=true forced — building on VM (legacy)"
        step_docker_remote
    else
        step_docker_local
    fi
}

# ── Step: Build nix flake (or copy-only for non-nix services) ────────
step_build() {
    CURRENT_STEP="build"

    # Simple copy mode: no nix, just copy src/ → dist/
    if [ "$BUILD_COPY_ONLY" = "true" ]; then
        log "Copying src/ -> dist/ (copy-only mode)"
        # Preserve terraform state if present
        if [ "$TERRAFORM_DEPLOY" = "true" ] && [ -d "$DIST_DIR" ]; then
            TF_BACKUP=$(mktemp -d)
            for f in terraform.tfstate terraform.tfstate.backup terraform.tfvars .terraform; do
                [ -e "$DIST_DIR/$f" ] && mv "$DIST_DIR/$f" "$TF_BACKUP/"
            done
            # Also preserve any .tfstate backups
            find "$DIST_DIR" -name '*.backup' -exec mv {} "$TF_BACKUP/" \; 2>/dev/null || true
        fi
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR"
        cp -r "$SRC_DIR/"* "$DIST_DIR/"
        # Restore terraform state
        if [ -n "${TF_BACKUP:-}" ] && [ -d "$TF_BACKUP" ]; then
            cp -a "$TF_BACKUP/"* "$DIST_DIR/" 2>/dev/null || true
            rm -rf "$TF_BACKUP"
        fi
        chmod -R u+w "$DIST_DIR"
        log "Built files:"
        find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
        return 0
    fi

    # Pre-build: update cloud-data submodule + copy files into src/
    # (nix flakes can't see git submodule contents — this bridges the gap)
    CLOUD_DATA_STAGED=""
    if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        # In CI, cloud-builder-ship.sh pre-stages all files before parallel dispatch
        # to avoid git index race conditions. Only do this in local/serial builds.
        CLOUD_DATA_DIR="$SERVICE_DIR/../../cloud-data"
        # Auto-update submodule to latest remote
        if [ -f "$SERVICE_DIR/../../.gitmodules" ]; then
            log "Updating cloud-data submodule to latest"
            git -C "$SERVICE_DIR/../.." submodule update --remote --init cloud-data 2>/dev/null || true
        fi
        if [ -d "$CLOUD_DATA_DIR" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                BASENAME=$(basename "$f")
                TARGET="$SRC_DIR/$BASENAME"
                # Skip files already committed in src/ — don't overwrite with submodule copy
                if git -C "$SERVICE_DIR/../.." ls-files --error-unmatch "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" >/dev/null 2>&1; then
                    continue
                fi
                cp "$f" "$TARGET"
                git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" 2>/dev/null || true
                CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $TARGET"
            done
            log "Staged cloud-data/*.json into src/ for nix build"
        fi
    elif [ "$INCLUDE_CLOUD_DATA" = "true" ]; then
        log "cloud-data already pre-staged by CI — skipping"
    fi

    # Inject build.json into src/ so flakes can read ports/config
    if [ -f "$SERVICE_DIR/build.json" ]; then
        cp "$SERVICE_DIR/build.json" "$SRC_DIR/build.json"
        git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$SRC_DIR/build.json")" 2>/dev/null || true
        log "Injected build.json into src/ for nix evaluation"
    fi

    log "Building nix flake -> dist/"
    cd "$SRC_DIR"

    BUILD_LOG=$(mktemp)
    REPO_ROOT="$SERVICE_DIR/../.."

    # nix build — runs directly (in GHA this is already inside cloud-builder container)
    git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true
    nix build --option eval-cache false --out-link "$SERVICE_DIR/.result" 2>"$BUILD_LOG" || {
        log_error "nix build failed:"
        cat "$BUILD_LOG" >&2
        rm -f "$BUILD_LOG"
        for f in $CLOUD_DATA_STAGED; do
            git -C "$REPO_ROOT" reset HEAD "$(realpath --relative-to="$REPO_ROOT" "$f")" 2>/dev/null || true
            rm -f "$f"
        done
        return 1
    }

    # Show warnings
    if [ -s "$BUILD_LOG" ]; then
        grep -i 'warning\|error\|trace' "$BUILD_LOG" | while IFS= read -r line; do
            log_warn "$line"
        done
    fi
    rm -f "$BUILD_LOG"

    # Copy from .result to dist/
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        cp -ra "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    else
        cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    fi
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    # Post-build: unstage and remove cloud-data files from src/
    # In CI, cleanup is handled by cloud-builder-ship.sh after all parallel jobs finish
    if [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        for f in $CLOUD_DATA_STAGED; do
            git -C "$SERVICE_DIR/../.." reset HEAD "$(realpath --relative-to="$SERVICE_DIR/../.." "$f")" 2>/dev/null || true
            rm -f "$f"
        done
    fi

    # Carry over docker source hash from step_docker (if image was rebuilt)
    if [ -f "$SERVICE_DIR/.docker-src-hash-new" ]; then
        mv "$SERVICE_DIR/.docker-src-hash-new" "$DIST_DIR/.docker-src-hash"
    fi

    # Include cloud-data/ files in dist/ for runtime use (e.g. C3 API needs topology)
    if [ "$INCLUDE_CLOUD_DATA" = "true" ]; then
        CLOUD_DATA_DIR="$SERVICE_DIR/../../cloud-data"
        FRONT_DATA_DIR="$SERVICE_DIR/../../front-data"
        REPO_ROOT="$SERVICE_DIR/../.."
        if [ -d "$CLOUD_DATA_DIR" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json "$CLOUD_DATA_DIR"/*.md; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included cloud-data/*.json + *.md in dist/"
        fi
        # Include config.json from repo root (needed by cloud-cgc-mcp)
        if [ -f "$REPO_ROOT/config.json" ]; then
            cp "$REPO_ROOT/config.json" "$DIST_DIR/"
            log "Included config.json in dist/"
        fi
        # Include front-data/*.json if available
        if [ -d "$FRONT_DATA_DIR" ]; then
            for f in "$FRONT_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included front-data/*.json in dist/"
        fi
    fi

    # Source hash for REMOTE_BUILD — TS/JS changes must trigger Docker rebuild
    # dist/ only has docker-compose.yml; source goes via rsync. Without this,
    # the ship hash check sees "unchanged" and skips compose (stale container).
    if [ -n "$DOCKER_IMAGE" ]; then
        find "$SRC_DIR" -name '*.ts' -o -name '*.js' -o -name 'Dockerfile' -o -name 'package.json' 2>/dev/null \
            | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16 > "$DIST_DIR/.src-hash"
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
    CURRENT_STEP="docs"
    log "Building documentation..."
    cd "$SRC_DIR"

    DEPS_FLAKE="$SERVICE_DIR/../../workflows/src/cloud-builder"
    if [ -d "$DEPS_FLAKE" ] && command -v nix >/dev/null 2>&1; then
        nix develop "$DEPS_FLAKE#" --command bash -c "cd '$SRC_DIR' && nix build --option eval-cache false .#docs --out-link '$SERVICE_DIR/.result-docs'"
    else
        nix build --option eval-cache false .#docs --out-link "$SERVICE_DIR/.result-docs"
    fi

    mkdir -p "$DIST_DIR/docs"
    cp -rL "$SERVICE_DIR/.result-docs/"* "$DIST_DIR/docs/"
    chmod -R u+w "$DIST_DIR/docs"
    rm -f "$SERVICE_DIR/.result-docs"

    log "Documentation built -> dist/docs/"
}

# ── Step: Decrypt secrets ────────────────────────────────────────────
step_secrets() {
    CURRENT_STEP="secrets"
    secrets_file="$SRC_DIR/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml -- skipping"
        return 0
    fi

    log "Decrypting secrets -> dist/.secrets"
    mkdir -p "$DIST_DIR"

    # Decrypt → write ALL keys to both:
    #   .secrets     = KEY=VALUE lines (docker-compose env_file)
    #   .secrets.d/  = one raw file per key (ssh-keys.nix, file mounts)
    # JWKS keys excluded (extracted separately below).
    if ! command -v yq >/dev/null 2>&1; then
        log "ERROR: yq required for YAML->env conversion"
        return 1
    fi

    mkdir -p "$DIST_DIR/.secrets.d"
    DECRYPTED=$(sops -d "$secrets_file")
    KEY_COUNT=0
    : > "$DIST_DIR/.secrets"

    for key in $(printf '%s' "$DECRYPTED" | yq -r 'keys | .[] | select(. != "sops")'); do
        [ -n "$JWKS_FILE" ] && [ "$key" = "AUTHELIA_OIDC_JWKS_KEY" ] && continue
        val=$(printf '%s' "$DECRYPTED" | yq -r ".[\"$key\"]")
        # .secrets.d/KEY — raw file (always written)
        printf '%s\n' "$val" > "$DIST_DIR/.secrets.d/$key"
        chmod 600 "$DIST_DIR/.secrets.d/$key"
        # .secrets — KEY=VALUE (skip multiline values — they break env_file parsing)
        line_count=$(printf '%s' "$val" | wc -l)
        if [ "$line_count" -gt 0 ]; then
            log "  $key: multiline — .secrets.d only"
        else
            printf '%s=%s\n' "$key" "$val" >> "$DIST_DIR/.secrets"
        fi
        KEY_COUNT=$((KEY_COUNT + 1))
    done

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

# ── Step: Deploy dist/ to VM via rsync (manifest-based) ──────────────
# Additive sync + manifest cleanup: only removes files the engine previously
# deployed that are no longer in dist/. Runtime state (DBs, caches, logs)
# is never touched because it was never in the manifest.
step_deploy() {
    CURRENT_STEP="deploy"
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
    ssh $SSH_OPTS "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"

    MANIFEST_FILE=".deploy-manifest"

    # 1. Build list of files we're about to deploy (relative paths)
    NEW_MANIFEST=$(cd "$DIST_DIR" && find . -type f | sort)

    # 2. Read old manifest from remote (may be empty on first deploy)
    OLD_MANIFEST=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/$MANIFEST_FILE' 2>/dev/null" || true)

    # 3. Build rsync exclude flags from build.json array
    RSYNC_EXCLUDES=""
    EXCLUDES="$(get_config_array deploy.excludes)"
    if [ -n "$EXCLUDES" ]; then
        RSYNC_EXCLUDES=$(echo "$EXCLUDES" | while IFS= read -r ex; do
            [ -n "$ex" ] && printf " --exclude '%s'" "$ex"
        done)
    fi

    # 3b. Clean specified subdirectories (deploy.clean_dirs) — ensures exact mirror
    CLEAN_DIRS="$(get_config_array deploy.clean_dirs)"
    if [ -n "$CLEAN_DIRS" ]; then
        echo "$CLEAN_DIRS" | while IFS= read -r d; do
            [ -z "$d" ] && continue
            log "  clean: $DEPLOY_PATH/$d/"
            ssh $SSH_OPTS "$DEPLOY_HOST" "rm -rf '$DEPLOY_PATH/$d/'"
        done
    fi

    # 4. Additive rsync (NO --delete) — adds/updates files, never removes
    if command -v rsync >/dev/null 2>&1; then
        eval rsync -az --compress-level=9 --checksum --partial --inplace --exclude='docs/' $RSYNC_EXCLUDES '"$DIST_DIR/"' '"$DEPLOY_HOST:$DEPLOY_PATH/"'
    elif command -v rclone >/dev/null 2>&1; then
        rclone copy "$DIST_DIR/" ":sftp:$DEPLOY_PATH/" \
            --sftp-host="$(ssh -G "$DEPLOY_HOST" | grep '^hostname ' | awk '{print $2}')" \
            --sftp-user="$(ssh -G "$DEPLOY_HOST" | grep '^user ' | awk '{print $2}')" \
            --sftp-key-file="$(ssh -G "$DEPLOY_HOST" | grep '^identityfile ' | head -1 | awk '{print $2}')" \
            --transfers=4
    else
        log "ERROR: No rsync or rclone available"
        return 1
    fi

    # 5. Clean stale files: in old manifest but not in new
    if [ -n "$OLD_MANIFEST" ]; then
        STALE_COUNT=0
        # Write manifests to temp files for reliable comparison (avoids subshell issues)
        OLD_TMP=$(mktemp)
        NEW_TMP=$(mktemp)
        echo "$OLD_MANIFEST" | sort > "$OLD_TMP"
        echo "$NEW_MANIFEST" | sort > "$NEW_TMP"
        # comm -23: lines only in old (stale files)
        STALE_FILES=$(comm -23 "$OLD_TMP" "$NEW_TMP")
        rm -f "$OLD_TMP" "$NEW_TMP"
        if [ -n "$STALE_FILES" ]; then
            echo "$STALE_FILES" | while IFS= read -r f; do
                [ -z "$f" ] && continue
                log "  rm stale: $f"
                ssh $SSH_OPTS "$DEPLOY_HOST" "rm -f '$DEPLOY_PATH/$f'"
                STALE_COUNT=$((STALE_COUNT + 1))
            done
            log "Cleaned stale files from previous deploy"
        fi
    fi

    # 6. Save new manifest to remote
    echo "$NEW_MANIFEST" | ssh $SSH_OPTS "$DEPLOY_HOST" "cat > '$DEPLOY_PATH/$MANIFEST_FILE'"

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"
}

# ── Step: Docker compose on VM ───────────────────────────────────────
step_compose() {
    CURRENT_STEP="compose"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Ensure Docker daemon is running on target VM (start if not)
    if ! ssh $SSH_OPTS "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
        log_warn "Docker daemon not running on $DEPLOY_HOST — starting it"
        ssh $SSH_OPTS "$DEPLOY_HOST" "sudo systemctl start docker" 2>/dev/null || true
        sleep 3
        if ! ssh $SSH_OPTS "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
            log_error "Docker daemon failed to start on $DEPLOY_HOST"
            return 1
        fi
        log "Docker daemon started on $DEPLOY_HOST"
    fi

    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"

    # Image strategy: binary > registry pull (always fresh)
    if [ -n "$DOCKER_BINARY" ] && ssh $SSH_OPTS "$DEPLOY_HOST" "test -f $DEPLOY_PATH/$DOCKER_BINARY_NAME -a -f $DEPLOY_PATH/Dockerfile.runtime" 2>/dev/null; then
        log "Building image locally on $DEPLOY_HOST (from pre-compiled binary)"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker build -q -t $FULL_IMAGE:latest -f Dockerfile.runtime ."
        log "Image built locally"
    elif [ -n "$FULL_IMAGE" ]; then
        log "Pulling latest image from registry"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose pull --ignore-buildable" || true
    fi

    # Pre-compose hook (e.g. mailu init.sh)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        log "Running pre-compose hook: $COMPOSE_PRE_HOOK"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK"
    fi

    ENV_FILE_FLAG="\$([ -f .secrets ] && echo '--env-file .secrets')"

    if [ "$SEQUENTIAL_RESTART" = "true" ]; then
        # Sequential restart: down -> settle -> start (avoids CPU spike on low-resource VMs)
        # Uses 'down' not 'stop' to release port bindings (stop keeps them bound)
        log "Stopping containers on $DEPLOY_HOST"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose down --remove-orphans" || true
        log "Waiting for CPU to settle..."
        sleep 5
        log "Starting containers on $DEPLOY_HOST:$DEPLOY_PATH"
        # Only --build on ARM VMs (oci-apps*). x86 VMs use pre-built GHCR images — NEVER build on host.
        BUILD_FLAG=""
        case "$DEPLOY_HOST" in oci-apps|oci-apps-1|oci-apps-2) BUILD_FLAG="--build" ;; esac
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose $ENV_FILE_FLAG up -d $BUILD_FLAG"
    else
        # Standard: pull first (while old containers run), then down + up (instant, no pulling)
        EXTRA_FLAGS="${COMPOSE_FLAGS:-}"
        log "Pulling images on $DEPLOY_HOST (one at a time, old containers keep running)"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && for svc in \$(docker compose config --services 2>/dev/null); do echo \"  pull: \$svc\"; docker compose $ENV_FILE_FLAG pull --ignore-buildable \$svc 2>/dev/null || true; done"
        log "Rebuilding $SERVICE_NAME on $DEPLOY_HOST:$DEPLOY_PATH"
        # Only --build on ARM VMs. x86 VMs (gcp-proxy, oci-mail, oci-analytics) use pre-built images.
        BUILD_FLAG=""
        case "$DEPLOY_HOST" in oci-apps|oci-apps-1|oci-apps-2) BUILD_FLAG="--build" ;; esac
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose down --remove-orphans 2>/dev/null; docker compose $ENV_FILE_FLAG up -d --force-recreate $BUILD_FLAG $EXTRA_FLAGS"
    fi

    # Post-compose hook (e.g. mailu setup.sh)
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        log "Running post-compose hook: $COMPOSE_POST_HOOK"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_POST_HOOK && ./$COMPOSE_POST_HOOK"
    fi

    # Verify containers actually started (not just Created)
    log "Verifying containers are running..."
    sleep 3
    local failed_containers
    failed_containers=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose ps --format '{{.Name}} {{.State}}' 2>/dev/null | grep -v 'running\|exited' || true")
    if [ -n "$failed_containers" ]; then
        log "ERROR: Some containers failed to start:"
        echo "$failed_containers" | while read -r line; do log "  $line"; done
        # Show logs of failed containers
        echo "$failed_containers" | while read -r cname cstate; do
            log "  Logs for $cname:"
            ssh $SSH_OPTS "$DEPLOY_HOST" "docker logs --tail 20 $cname 2>&1" | while read -r l; do log "    $l"; done
        done
        return 1
    fi
    log "All containers running"
}

# ── Health verification (post-deploy) ─────────────────────────────────
# Waits for containers to pass Docker healthcheck or be stably running.
# Detects crash loops (container restarting) and reports failure.
# Timeout and interval are configurable; defaults: 120s timeout, 10s interval.
step_health() {
    CURRENT_STEP="health"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping health"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    local timeout="${HEALTH_TIMEOUT:-120}"
    local interval="${HEALTH_INTERVAL:-10}"
    local elapsed=0

    log "Waiting for containers to be healthy (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        # Get all container statuses from compose project
        local statuses
        statuses=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose ps --format '{{.Name}}|{{.State}}|{{.Health}}' 2>/dev/null" || true)

        if [ -z "$statuses" ]; then
            log "WARNING: No containers found"
            return 1
        fi

        local all_ok=true
        local has_health=false

        while IFS='|' read -r cname cstate chealth; do
            [ -z "$cname" ] && continue

            # Crash loop detection: "restarting" state
            if echo "$cstate" | grep -qi "restarting"; then
                log "FAIL: $cname is crash-looping"
                ssh $SSH_OPTS "$DEPLOY_HOST" "docker logs --tail 15 $cname 2>&1" | while read -r l; do log "  $l"; done
                return 1
            fi

            # Container with healthcheck defined
            if [ -n "$chealth" ] && [ "$chealth" != "" ]; then
                has_health=true
                if echo "$chealth" | grep -qi "healthy"; then
                    : # healthy, good
                elif echo "$chealth" | grep -qi "unhealthy"; then
                    log "FAIL: $cname is unhealthy"
                    ssh $SSH_OPTS "$DEPLOY_HOST" "docker logs --tail 15 $cname 2>&1" | while read -r l; do log "  $l"; done
                    return 1
                else
                    all_ok=false  # still starting
                fi
            else
                # No healthcheck — just verify running
                if ! echo "$cstate" | grep -qi "running"; then
                    if echo "$cstate" | grep -qi "exited"; then
                        : # one-shot containers (init, migrations) are OK
                    else
                        all_ok=false
                    fi
                fi
            fi
        done <<EOF
$statuses
EOF

        if [ "$all_ok" = "true" ]; then
            log "All containers healthy (${elapsed}s)"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    # Timeout — show final state
    log "TIMEOUT: Not all containers healthy after ${timeout}s"
    ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose ps" 2>/dev/null | while read -r l; do log "  $l"; done
    return 1
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
                ssh $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml stop" || true
                ;;
            compose_start)
                log "  Starting compose at $VM:$COMPOSE_PATH"
                ssh $SSH_OPTS "$VM" "docker compose -f $COMPOSE_PATH/docker-compose.yml start"
                ;;
            exec)
                log "  Exec in $CONTAINER on $VM: $SCRIPT"
                ssh $SSH_OPTS "$VM" "docker exec $CONTAINER $SCRIPT" || true
                ;;
            stats)
                ssh $SSH_OPTS "$VM" "free -h && echo '---' && docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'"
                ;;
        esac
    done

    log "Lifecycle $COMMAND complete"
}

# ── Step: Deploy Cloudflare Worker via wrangler ──────────────────────
step_wrangler() {
    CURRENT_STEP="wrangler"
    [ "$WRANGLER_DEPLOY" != "true" ] && { log "No deploy.wrangler -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v wrangler >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
        log_error "wrangler or npx not found. Install: npm install -g wrangler"
        return 1
    fi

    # Source Cloudflare credentials from vault (same auto-detect as SOPS_AGE_KEY_FILE)
    if [ -z "${CLOUDFLARE_API_KEY:-}" ]; then
        for cf_env in \
            "$HOME/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env" \
            "/home/diego/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env"; do
            if [ -f "$cf_env" ]; then
                CLOUDFLARE_API_KEY=$(grep '^CF_API_KEY=' "$cf_env" | cut -d= -f2)
                CLOUDFLARE_EMAIL=$(grep '^CF_API_EMAIL=' "$cf_env" | cut -d= -f2)
                export CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
                log "Loaded Cloudflare credentials from vault"
                break
            fi
        done
    fi

    if [ -z "${CLOUDFLARE_API_KEY:-}" ]; then
        log_error "CLOUDFLARE_API_KEY not set and not found in vault"
        return 1
    fi

    log "Deploying Worker to Cloudflare..."
    cd "$DIST_DIR"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler deploy
    else
        npx wrangler deploy
    fi
    log "Worker deployed to Cloudflare"
}

# ── Step: Terraform (init + apply in dist/) ──────────────────────────
step_terraform() {
    CURRENT_STEP="terraform"
    [ "$TERRAFORM_DEPLOY" != "true" ] && { log "No deploy.terraform -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v terraform >/dev/null 2>&1; then
        log_error "terraform not found on PATH"
        return 1
    fi

    # Generate terraform.tfvars from template (always), then substitute secrets (if present)
    TFVARS_TEMPLATE="$SRC_DIR/${TERRAFORM_TFVARS_TEMPLATE:-terraform.tfvars.template}"
    if [ -f "$TFVARS_TEMPLATE" ]; then
        cp "$TFVARS_TEMPLATE" "$DIST_DIR/terraform.tfvars"
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Substituting secrets into terraform.tfvars"
            while IFS='=' read -r key val; do
                case "$key" in "") continue ;; esac
                awk -v pat="= \"INJECTED_FROM_SECRETS\"" -v key="$key" -v val="$val" '{
                    if (index($0, key) == 1 && index($0, pat)) {
                        print key " = \"" val "\""
                    } else {
                        print
                    }
                }' "$DIST_DIR/terraform.tfvars" > "$DIST_DIR/terraform.tfvars.tmp"
                mv "$DIST_DIR/terraform.tfvars.tmp" "$DIST_DIR/terraform.tfvars"
            done < "$DIST_DIR/.secrets"
        fi
        log "terraform.tfvars ready ($(grep -c '=' "$DIST_DIR/terraform.tfvars") vars)"
    fi

    log "terraform init"
    (cd "$DIST_DIR" && terraform init -upgrade -input=false)
    log "terraform plan"
    (cd "$DIST_DIR" && terraform plan)
    log "terraform apply -auto-approve"
    (cd "$DIST_DIR" && terraform apply -auto-approve)
    log "Terraform applied"
}

# ── Step: Terraform plan (non-destructive) ───────────────────────────
step_terraform_plan() {
    CURRENT_STEP="terraform-plan"
    [ "$TERRAFORM_DEPLOY" != "true" ] && { log "No deploy.terraform -- skipping"; return 0; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    if ! command -v terraform >/dev/null 2>&1; then
        log_error "terraform not found on PATH"
        return 1
    fi

    # Generate tfvars from template (always), then substitute secrets (if present)
    TFVARS_TEMPLATE="$SRC_DIR/${TERRAFORM_TFVARS_TEMPLATE:-terraform.tfvars.template}"
    if [ -f "$TFVARS_TEMPLATE" ] && [ ! -f "$DIST_DIR/terraform.tfvars" ]; then
        cp "$TFVARS_TEMPLATE" "$DIST_DIR/terraform.tfvars"
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Substituting secrets into terraform.tfvars"
            while IFS='=' read -r key val; do
                case "$key" in "") continue ;; esac
                awk -v pat="= \"INJECTED_FROM_SECRETS\"" -v key="$key" -v val="$val" '{
                    if (index($0, key) == 1 && index($0, pat)) {
                        print key " = \"" val "\""
                    } else {
                        print
                    }
                }' "$DIST_DIR/terraform.tfvars" > "$DIST_DIR/terraform.tfvars.tmp"
                mv "$DIST_DIR/terraform.tfvars.tmp" "$DIST_DIR/terraform.tfvars"
            done < "$DIST_DIR/.secrets"
        fi
        log "terraform.tfvars ready ($(grep -c '=' "$DIST_DIR/terraform.tfvars") vars)"
    fi

    log "terraform init"
    (cd "$DIST_DIR" && terraform init -upgrade -input=false) >/dev/null 2>&1
    log "terraform plan $*"
    (cd "$DIST_DIR" && terraform plan "$@")
}

# ── Step: Clean remote (remove non-manifest files) ───────────────────
# For intentional full cleanup of runtime state (DBs, caches, logs).
# Shows a dry-run first, requires explicit --force to actually delete.
step_clean_remote() {
    FORCE_FLAG="$1"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- nothing to clean"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set"; return 1; }

    MANIFEST_FILE=".deploy-manifest"
    MANIFEST=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/$MANIFEST_FILE' 2>/dev/null" || true)

    if [ -z "$MANIFEST" ]; then
        log "No deploy manifest found — cannot determine engine-owned files"
        log "Run 'build.sh ship' first to establish a manifest"
        return 1
    fi

    # List all files on remote, find those NOT in manifest
    ALL_REMOTE=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cd '$DEPLOY_PATH' && find . -type f | sort")
    MANIFEST_TMP=$(mktemp)
    REMOTE_TMP=$(mktemp)
    KNOWN_TMP=$(mktemp)
    echo "$ALL_REMOTE" > "$REMOTE_TMP"
    # Known files = manifest + the manifest file itself
    { echo "$MANIFEST"; echo "./$MANIFEST_FILE"; } | sort -u > "$KNOWN_TMP"

    # comm -23: lines only in remote (not in known) = extra files
    EXTRA_FILES=$(comm -23 "$REMOTE_TMP" "$KNOWN_TMP")
    rm -f "$MANIFEST_TMP" "$REMOTE_TMP" "$KNOWN_TMP"

    if [ -z "$EXTRA_FILES" ]; then
        log "No non-manifest files found — remote is clean"
        return 0
    fi

    log "Non-manifest files on $DEPLOY_HOST:$DEPLOY_PATH:"
    echo "$EXTRA_FILES" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "  $f"
    done

    if [ "$FORCE_FLAG" = "--force" ]; then
        log "Removing non-manifest files (--force)"
        echo "$EXTRA_FILES" | while IFS= read -r f; do
            [ -z "$f" ] && continue
            ssh $SSH_OPTS "$DEPLOY_HOST" "rm -f '$DEPLOY_PATH/$f'"
        done
        log "Remote cleaned"
    else
        log "Dry run — add --force to actually delete"
    fi
}

# ── Step: Compose build + push (GHCR images from dockerfile_inline) ──
# Builds all services in docker-compose.yml that have a `build:` section
# and pushes them to GHCR. Requires GHCR login before calling.
step_compose_build() {
    CURRENT_STEP="compose-build"
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }
    [ ! -f "$DIST_DIR/docker-compose.yml" ] && { log "No docker-compose.yml in dist/"; return 1; }

    # Docker CLI required (installed in cloud-builder image)
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "Docker CLI not available — skipping compose-build"
        return 0
    fi

    # Check if docker-compose.yml has any build: sections
    if ! grep -q 'dockerfile_inline:' "$DIST_DIR/docker-compose.yml" 2>/dev/null; then
        log "No dockerfile_inline in docker-compose.yml -- skipping compose-build"
        return 0
    fi

    log "Building + pushing GHCR images from docker-compose.yml"
    cd "$DIST_DIR"

    # GHCR login (GHA provides GITHUB_TOKEN, local uses gh auth token)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
    elif command -v gh >/dev/null 2>&1; then
        gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
    else
        log_warn "No GHCR credentials — skipping push (build-only)"
        docker compose build
        return 0
    fi

    # Auto-detect platform from deploy host (ARM VMs get multi-arch builds)
    PLATFORM=""
    case "$DEPLOY_HOST" in
        oci-apps|oci-apps-1|oci-apps-2)
            PLATFORM="linux/amd64,linux/arm64"
            log "ARM host detected ($DEPLOY_HOST) — building multi-arch: $PLATFORM"
            # Ensure buildx builder exists for multi-platform
            docker buildx inspect multiarch >/dev/null 2>&1 || \
                docker buildx create --name multiarch --use >/dev/null 2>&1
            docker buildx use multiarch 2>/dev/null
            ;;
        *)
            log "x86 host ($DEPLOY_HOST) — building linux/amd64"
            ;;
    esac

    # Build + push all services with build: sections (verbose output)
    log "── dockerfile_inline content ──"
    grep -A20 'dockerfile_inline:' "$DIST_DIR/docker-compose.yml" || true
    log "── docker compose build --push (verbose) ──"
    if [ -n "$PLATFORM" ]; then
        # Multi-arch: use buildx bake with platform override
        BUILDKIT_PROGRESS=plain docker buildx bake --push --progress=plain \
            --set "*.platform=$PLATFORM" \
            -f "$DIST_DIR/docker-compose.yml" 2>&1 | while IFS= read -r line; do
            printf "[compose-build] %s\n" "$line"
        done
    else
        BUILDKIT_PROGRESS=plain docker compose build --push --progress=plain 2>&1 | while IFS= read -r line; do
            printf "[compose-build] %s\n" "$line"
        done
    fi

    log "GHCR images built and pushed"

    # Verify all pushed packages are public (CRITICAL)
    if command -v gh >/dev/null 2>&1; then
        grep -o 'ghcr.io/diegonmarcos/[^:]*' "$DIST_DIR/docker-compose.yml" 2>/dev/null | sort -u | while read -r img; do
            PKG_NAME=$(echo "$img" | awk -F/ '{print $NF}')
            PKG_VIS=$(gh api "/user/packages/container/${PKG_NAME}" --jq '.visibility' 2>/dev/null || echo "unknown")
            if [ "$PKG_VIS" = "private" ]; then
                log_error "PRIVATE PACKAGE: $PKG_NAME — push from GHA to make public"
            fi
        done
    fi
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
    compose-build) step_compose_build ;;
    health)   step_health ;;
    all)      step_build; step_docs; step_secrets ;;
    ship)
        step_build
        step_docker
        step_secrets
        step_compose_build
        # Skip deploy+compose if dist/ output is unchanged since last ship
        NEW_HASH=$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
        # Read hash from VM (persists across ephemeral GHA runners)
        if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
            OLD_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/.dist-hash' 2>/dev/null" 2>/dev/null || true)
        else
            OLD_HASH=$(cat "$SERVICE_DIR/.dist-hash" 2>/dev/null || true)
        fi
        if [ "$OLD_HASH" = "$NEW_HASH" ] && [ -n "$NEW_HASH" ] && [ -z "$DOCKER_IMAGE_CHANGED" ] && [ -z "$FORCE_DEPLOY" ]; then
            log "Config unchanged, no image rebuild — skipping deploy+compose"
        elif [ "$WRANGLER_DEPLOY" = "true" ]; then
            step_wrangler
            echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
        elif [ "$TERRAFORM_DEPLOY" = "true" ]; then
            step_terraform
            echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
        else
            step_deploy
            step_compose
            # Write hash to both local and VM (VM hash survives ephemeral runners)
            echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
            if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
                ssh $SSH_OPTS "$DEPLOY_HOST" "echo '$NEW_HASH' > '$DEPLOY_PATH/.dist-hash'" 2>/dev/null || true
            fi
        fi
        ;;
    wrangler) step_wrangler ;;
    terraform) step_build; step_secrets; step_terraform ;;
    tf-plan) shift; step_build; step_secrets; step_terraform_plan "$@" ;;
    redeploy) step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result" "$SERVICE_DIR/.result-docs" "$SERVICE_DIR/.dist-hash"; log "Cleaned" ;;
    clean-remote) step_clean_remote "${2:-}" ;;
    *)
        # Try lifecycle command from build.json
        if [ -f "$CONFIG" ] && get_lifecycle "$1" | grep -q .; then
            run_lifecycle "$1"
        else
            echo "Usage: $0 [docker|build|docs|secrets|deploy|compose|health|wrangler|all|ship|redeploy|clean|clean-remote|<lifecycle>]"
            echo "  docker       Build + push Docker image"
            echo "  build        Build nix flake -> dist/"
            echo "  docs         Build documentation -> dist/docs/"
            echo "  secrets      Decrypt secrets -> dist/.secrets"
            echo "  deploy       Rsync dist/ -> VM (manifest-based, no --delete)"
            echo "  compose      Docker compose up on VM"
            echo "  health       Verify containers are healthy (post-deploy)"
            echo "  wrangler     Deploy Cloudflare Worker via wrangler"
            echo "  terraform    Terraform init + apply in dist/"
            echo "  tf-plan      build + secrets + terraform plan"
            echo "  all          build + docs + secrets (default)"
            echo "  ship         docker + build + secrets + deploy + compose (skips if unchanged)"
            echo "  redeploy     build + secrets + deploy + compose (skip docker)"
            echo "  clean        Remove dist/ and build artifacts"
            echo "  clean-remote List non-manifest files on VM (--force to delete)"
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

CURRENT_STEP=""
log "Done."
