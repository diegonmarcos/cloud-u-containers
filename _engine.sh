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
    DOCKER_ARCH="$(get_config docker.arch)"
    SEQUENTIAL_RESTART="$(get_config deploy.sequential_restart)"
    COMPOSE_FLAGS="$(get_config deploy.compose_flags)"
    ESCAPE_DOLLARS="$(get_config secrets.escape_dollars)"
    JWKS_FILE="$(get_config secrets.jwks_file)"
    JWKS_DEST="$(get_config secrets.jwks_dest)"
    PRESERVE_SYMLINKS="$(get_config build.preserve_symlinks)"
    INCLUDE_CLOUD_DATA="$(get_config build.include_cloud_data)"
    COMPOSE_PRE_HOOK="$(get_config compose.pre_hook)"
    COMPOSE_POST_HOOK="$(get_config compose.post_hook)"
    COMPOSE_CUSTOM="$(get_config compose.custom)"
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
# Unified docker build: uses cloud-builder container for all builds.
# Runner is set by `build.sh ship [runner]` (default: auto).
# Architecture is declared in build.json docker.arch (default: amd64).
step_docker() {
    [ -z "$DOCKER_IMAGE" ] && { log "No docker.image in build.json -- skipping"; return 0; }

    CURRENT_STEP="docker"
    FULL_IMAGE="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    DOCKERFILE="${DOCKER_FILE:-Dockerfile}"
    SHA_TAG="${GITHUB_SHA:-$(git -C "$SERVICE_DIR" rev-parse HEAD 2>/dev/null || echo local)}"

    # Architecture from build.json (declarative, no hostname inference)
    ARCH="${DOCKER_ARCH:-amd64}"
    PLATFORM="linux/$ARCH"
    log "Docker build: $FULL_IMAGE (arch: $ARCH, runner: ${RUNNER:-auto})"

    # Smart hash: skip rebuild when src/ unchanged
    LOCAL_HASH=$(find "$SRC_DIR" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -not -name 'secrets.yaml' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
        REMOTE_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat $DEPLOY_PATH/.docker-src-hash 2>/dev/null" 2>/dev/null || true)
        if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
            log "Docker src unchanged ($LOCAL_HASH) — skipping"
            return 0
        fi
        [ -n "$REMOTE_HASH" ] && log "Docker src changed ($REMOTE_HASH -> $LOCAL_HASH)"
    fi

    # Build context: prefer dist/ if Dockerfile exists there, else src/
    BUILD_CONTEXT="$SRC_DIR"
    if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/$DOCKERFILE" ]; then
        BUILD_CONTEXT="$DIST_DIR"
    fi
    DOCKERFILE_PATH="$BUILD_CONTEXT/$DOCKERFILE"

    # GHCR login
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>/dev/null
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>/dev/null
    fi

    # Dispatch based on runner
    case "${RUNNER:-auto}" in
        auto|local)
            # Ensure buildx builder exists
            docker buildx inspect multiarch >/dev/null 2>&1 || \
                docker buildx create --name multiarch --use >/dev/null 2>&1
            docker buildx use multiarch 2>/dev/null

            log "Building $FULL_IMAGE (platform: $PLATFORM) — local buildx"
            BUILDKIT_PROGRESS=plain docker buildx build \
                --progress=plain \
                --push \
                --no-cache \
                --platform "$PLATFORM" \
                --tag "$FULL_IMAGE:latest" \
                --tag "$FULL_IMAGE:$SHA_TAG" \
                --file "$DOCKERFILE_PATH" \
                "$BUILD_CONTEXT/" 2>&1 | while IFS= read -r line; do printf "[docker] %s\n" "$line"; done
            ;;

        oci-apps|oci-apps-1|oci-apps-2)
            # Build on ARM VM natively (fast, no QEMU)
            REMOTE_BUILD_DIR="/tmp/${SERVICE_NAME}-docker-build"
            log "Building $FULL_IMAGE on $RUNNER (native $ARCH)"
            ssh $SSH_OPTS "$RUNNER" "mkdir -p $REMOTE_BUILD_DIR"
            rsync -avzL --delete "$BUILD_CONTEXT/" "$RUNNER:$REMOTE_BUILD_DIR/"
            ssh $SSH_OPTS "$RUNNER" "cd $REMOTE_BUILD_DIR && DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain docker build --no-cache --progress=plain -t $FULL_IMAGE:latest -f $DOCKERFILE . 2>&1" | while IFS= read -r line; do printf "[docker-$RUNNER] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER" "ionice -c3 nice -n19 docker push $FULL_IMAGE:latest 2>&1" | while IFS= read -r line; do printf "[docker-$RUNNER] %s\n" "$line"; done
            ssh $SSH_OPTS "$RUNNER" "rm -rf $REMOTE_BUILD_DIR"
            ;;

        gha)
            log "Runner=gha — skipping docker build (CI handles it)"
            return 0
            ;;

        *)
            log_error "Unknown runner: $RUNNER (valid: auto, local, oci-apps, gha)"
            return 1
            ;;
    esac

    log "Pushed $FULL_IMAGE:latest"

    # Ensure GHCR package is public
    PKG_NAME=$(echo "$FULL_IMAGE" | awk -F/ '{print $NF}')
    if command -v gh >/dev/null 2>&1; then
        PKG_VIS=$(gh api "/user/packages/container/${PKG_NAME}" --jq '.visibility' 2>/dev/null || echo "unknown")
        if [ "$PKG_VIS" = "public" ]; then
            log "Package $PKG_NAME: public ✓"
        elif [ "$PKG_VIS" = "private" ]; then
            log_error "PRIVATE PACKAGE: $PKG_NAME — needs GHA push to make public"
        fi
    fi

    echo "$LOCAL_HASH" > "$SERVICE_DIR/.docker-src-hash-new"
    DOCKER_IMAGE_CHANGED=true

    # Extract binary if needed (e.g. Rust binaries)
    if [ -n "$DOCKER_BINARY" ]; then
        log "Extracting binary from image"
        docker pull "$FULL_IMAGE:latest"
        CONTAINER_ID=$(docker create "$FULL_IMAGE:latest")
        docker cp "$CONTAINER_ID:$DOCKER_BINARY" "/tmp/${SERVICE_NAME}-binary"
        docker rm "$CONTAINER_ID"
        log "Extracted binary ($(du -h "/tmp/${SERVICE_NAME}-binary" | cut -f1))"
    fi
}

# ── Step: Push configs image to GHCR (dist/ → busybox wrapper → GHCR) ─
step_configs_push() {
    CURRENT_STEP="configs-push"
    [ ! -d "$DIST_DIR" ] && { log "No dist/ — skipping configs push"; return 0; }
    [ ! -f "$DIST_DIR/docker-compose.yml" ] && { log "No docker-compose.yml — skipping configs push"; return 0; }

    CONFIGS_IMAGE="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}/${SERVICE_NAME}-configs:latest"

    # Skip if dist/ unchanged since last configs push
    CONFIGS_HASH=$(find "$DIST_DIR" -type f ! -name 'Dockerfile.configs' ! -name '.configs-hash' -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
    OLD_CONFIGS_HASH=$(cat "$SERVICE_DIR/.configs-hash" 2>/dev/null || echo "")
    if [ "$CONFIGS_HASH" = "$OLD_CONFIGS_HASH" ] && [ -n "$CONFIGS_HASH" ]; then
        log "Configs unchanged — skipping push ($CONFIGS_HASH)"
        return 0
    fi

    # GHCR login
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin 2>/dev/null
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null | docker login ghcr.io -u "$(gh api user --jq .login 2>/dev/null)" --password-stdin 2>/dev/null
    else
        log_warn "No GHCR credentials — skipping configs push"
        return 0
    fi

    # Generate Dockerfile: busybox + all dist/ files EXCEPT secrets → /configs/
    # Backup existing .dockerignore, replace with secrets-excluding one
    [ -f "$DIST_DIR/.dockerignore" ] && cp "$DIST_DIR/.dockerignore" "$DIST_DIR/.dockerignore.bak"
    cat > "$DIST_DIR/.dockerignore" <<'DEOF'
.secrets
.secrets.d/
*.key
*.pem
*.age
Dockerfile.configs
.dockerignore.bak
.configs-hash
DEOF
    cat > "$DIST_DIR/Dockerfile.configs" <<'DEOF'
FROM busybox:latest
COPY . /configs/
CMD ["sh", "-c", "cp -r /configs/. /out/ && echo '[configs] extracted to /out'"]
DEOF

    log "Building configs image: $CONFIGS_IMAGE"
    docker build -q -t "$CONFIGS_IMAGE" -f "$DIST_DIR/Dockerfile.configs" "$DIST_DIR" || {
        log_warn "Configs image build failed (non-fatal)"
        return 0
    }
    docker push "$CONFIGS_IMAGE" 2>&1 | tail -3
    # Restore original .dockerignore
    rm -f "$DIST_DIR/Dockerfile.configs"
    if [ -f "$DIST_DIR/.dockerignore.bak" ]; then
        mv "$DIST_DIR/.dockerignore.bak" "$DIST_DIR/.dockerignore"
    else
        rm -f "$DIST_DIR/.dockerignore"
    fi
    echo "$CONFIGS_HASH" > "$SERVICE_DIR/.configs-hash"
    log "Pushed configs image: $CONFIGS_IMAGE ($CONFIGS_HASH) — secrets EXCLUDED"
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

    # build.json: src/build.json is a symlink to ../build.json (root is source of truth)
    if [ -f "$SERVICE_DIR/build.json" ] && [ ! -L "$SRC_DIR/build.json" ]; then
        ln -sf ../build.json "$SRC_DIR/build.json"
        git -C "$SERVICE_DIR/../.." add -f "$(realpath --relative-to="$SERVICE_DIR/../.." "$SRC_DIR/build.json")" 2>/dev/null || true
        log "Created build.json symlink in src/"
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

    # docker-run.sh generation moved to step_compose (compose.custom=true in build.json)

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

    # sops decrypt → dotenv, then single-quote values containing $ so
    # docker-compose env_file doesn't interpolate them as variables
    sops -d --output-type dotenv "$secrets_file" | node -e "
const lines = require('fs').readFileSync(0,'utf8').split('\n');
for (const line of lines) {
  if (!line || line.startsWith('#')) { console.log(line); continue; }
  const eq = line.indexOf('=');
  if (eq < 0) { console.log(line); continue; }
  const k = line.slice(0, eq);
  const v = line.slice(eq + 1);
  // Single-quote values with \$ — compose treats single-quoted as literal
  console.log(v.includes('\$') ? k + \"='\" + v + \"'\" : line);
}
" > "$DIST_DIR/.secrets"

    # Extract JWKS key as PEM file (multi-line value can't go in env_file)
    if [ -n "$JWKS_FILE" ] && [ -f "$SRC_DIR/$JWKS_FILE" ]; then
        JWKS_DEST_PATH="${JWKS_DEST:-config/oidc_jwks.pem}"
        mkdir -p "$DIST_DIR/$(dirname "$JWKS_DEST_PATH")"
        sops -d --extract '["key"]' "$SRC_DIR/$JWKS_FILE" > "$DIST_DIR/$JWKS_DEST_PATH"
        chmod 600 "$DIST_DIR/$JWKS_DEST_PATH"
        log "JWKS key -> $JWKS_DEST_PATH"
    fi

    log "Secrets decrypted"
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

    # ── Deploy: configs image (GHCR) + secrets (scp) — universal, all VMs ──
    CONFIGS_IMAGE="${DOCKER_REGISTRY:-ghcr.io/diegonmarcos}/${SERVICE_NAME}-configs:latest"

    log "Deploying via configs image: $CONFIGS_IMAGE"
    ssh $SSH_OPTS "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH && \
        docker pull $CONFIGS_IMAGE && \
        docker run --rm -v $DEPLOY_PATH:/out $CONFIGS_IMAGE && \
        sudo chown -R \$(whoami):\$(whoami) $DEPLOY_PATH" && {
        log "Deployed configs to $DEPLOY_HOST:$DEPLOY_PATH (via configs image)"
    } || {
        log_warn "Configs image deploy failed — falling back to rsync"
        # Rsync fallback (only if configs image unavailable, e.g. first-ever ship)
        log "Deploying dist/ -> $DEPLOY_HOST:$DEPLOY_PATH (rsync fallback)"
        ssh $SSH_OPTS "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"
        rsync -az --compress-level=9 --checksum "$DIST_DIR/" "$DEPLOY_HOST:$DEPLOY_PATH/" 2>/dev/null || true
    }

    # Secrets: ALWAYS via scp (never in GHCR image)
    if [ -f "$DIST_DIR/.secrets" ]; then
        scp $SSH_OPTS "$DIST_DIR/.secrets" "$DEPLOY_HOST:$DEPLOY_PATH/.secrets" 2>/dev/null && \
            log "Deployed .secrets via scp" || log_warn ".secrets scp failed"
    fi
    if [ -d "$DIST_DIR/.secrets.d" ]; then
        scp $SSH_OPTS -r "$DIST_DIR/.secrets.d" "$DEPLOY_HOST:$DEPLOY_PATH/.secrets.d" 2>/dev/null && \
            log "Deployed .secrets.d via scp" || log_warn ".secrets.d scp failed"
    fi

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"

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

# ── Step: Run containers on VM via docker compose ──────────────────
step_compose() {
    CURRENT_STEP="compose"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Ensure Docker daemon is running
    if ! ssh $SSH_OPTS "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
        log_warn "Docker not running on $DEPLOY_HOST — starting"
        ssh $SSH_OPTS "$DEPLOY_HOST" "sudo systemctl start docker" 2>/dev/null || true
        sleep 5
        if ! ssh $SSH_OPTS "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
            log_error "Docker failed to start on $DEPLOY_HOST"
            return 1
        fi
    fi

    # Pre-hook (runs on VM before containers start)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        if ssh $SSH_OPTS "$DEPLOY_HOST" "grep -q 'entrypoint.*$COMPOSE_PRE_HOOK' $DEPLOY_PATH/docker-compose.yml 2>/dev/null"; then
            log "Skipping pre_hook '$COMPOSE_PRE_HOOK' — container entrypoint"
        else
            log "Running pre-hook: $COMPOSE_PRE_HOOK"
            ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK"
        fi
    fi

    if [ "$COMPOSE_CUSTOM" = "true" ]; then
        # ── Custom compose script: self-contained, used by both ship + container-init ──
        SCRIPT_NAME="build-step-compose-custom.sh"
        log "Generating $SCRIPT_NAME"
        cat > "$DIST_DIR/$SCRIPT_NAME" <<'COMPOSE_SCRIPT'
#!/bin/sh
set -e
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  docker info >/dev/null 2>&1 || { echo "[compose-custom] ERROR: Docker failed to start" >&2; exit 1; }
fi
ENV_FILE_FLAG=""
[ -f .secrets ] && ENV_FILE_FLAG="--env-file .secrets"
docker compose $ENV_FILE_FLAG pull --quiet 2>/dev/null || true
docker compose $ENV_FILE_FLAG up -d --force-recreate
COMPOSE_SCRIPT
        chmod +x "$DIST_DIR/$SCRIPT_NAME"

        log "Deploying + running $SCRIPT_NAME on $DEPLOY_HOST"
        rsync -az "$DIST_DIR/$SCRIPT_NAME" "$DEPLOY_HOST:$DEPLOY_PATH/$SCRIPT_NAME"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && sh $SCRIPT_NAME"
    else
        # ── Standard: direct docker compose up ──
        ENV_FILE_FLAG="\$([ -f .secrets ] && echo '--env-file .secrets')"
        log "Running docker compose up on $DEPLOY_HOST:$DEPLOY_PATH"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose \$ENV_FILE_FLAG pull --quiet && docker compose \$ENV_FILE_FLAG up -d --force-recreate"
    fi

    # Post-hook
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        log "Running post-hook: $COMPOSE_POST_HOOK"
        ssh $SSH_OPTS "$DEPLOY_HOST" "cd $DEPLOY_PATH && chmod +x $COMPOSE_POST_HOOK && ./$COMPOSE_POST_HOOK"
    fi

    # Verify
    log "Verifying containers are running..."
    sleep 3
    ssh $SSH_OPTS "$DEPLOY_HOST" "docker ps --filter 'name=$(basename $DEPLOY_PATH)' --format '{{.Names}} {{.Status}}'" 2>/dev/null | while read -r line; do log "  $line"; done
    log "Done."
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
    # Wrangler auth priority: CLOUDFLARE_API_TOKEN > CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL
    # Clear ALL legacy/conflicting vars first so wrangler sees exactly what we set.
    unset CF_API_TOKEN CF_API_KEY CLOUDFLARE_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL 2>/dev/null || true

    for cf_env in \
        "$HOME/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env" \
        "/home/diego/git/vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env"; do
        if [ -f "$cf_env" ]; then
            # Use Global API Key (CF_API_KEY) — has all permissions including Workers
            _key=$(grep '^CF_API_KEY=' "$cf_env" | cut -d= -f2)
            _email=$(grep '^CF_API_EMAIL=' "$cf_env" | cut -d= -f2)
            if [ -n "$_key" ] && [ -n "$_email" ]; then
                CLOUDFLARE_API_KEY="$_key"
                CLOUDFLARE_EMAIL="$_email"
                export CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL
                log "Loaded Cloudflare Global API Key from vault"
                break
            fi
        fi
    done

    if [ -z "${CLOUDFLARE_API_KEY:-}" ]; then
        log_error "CLOUDFLARE_API_KEY not found in vault"
        return 1
    fi

    log "Deploying Worker to Cloudflare..."
    cd "$DIST_DIR"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler deploy
    else
        log_error "wrangler not found — install via nix or npm"
        return 1
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

    # Platform from build.json docker.arch (declarative, no hostname inference)
    ARCH="${DOCKER_ARCH:-amd64}"
    PLATFORM="linux/$ARCH"
    log "compose-build platform: $PLATFORM (from docker.arch)"
    docker buildx inspect multiarch >/dev/null 2>&1 || \
        docker buildx create --name multiarch --use >/dev/null 2>&1
    docker buildx use multiarch 2>/dev/null

    # Build + push all services with build: sections (verbose output)
    log "── dockerfile_inline content ──"
    grep -A20 'dockerfile_inline:' "$DIST_DIR/docker-compose.yml" || true
    log "── docker compose build --push (verbose) ──"
    COMPOSE_BUILD_OK=""
    if BUILDKIT_PROGRESS=plain docker buildx bake --no-cache --push --progress=plain \
        --set "*.platform=$PLATFORM" \
        -f "$DIST_DIR/docker-compose.yml" 2>&1 | while IFS= read -r line; do
        printf "[compose-build] %s\n" "$line"
    done; then
        COMPOSE_BUILD_OK=true
    fi

    if [ -z "$COMPOSE_BUILD_OK" ]; then
        log_error "compose-build FAILED — aborting ship to prevent deploying stale image"
        return 1
    fi

    DOCKER_IMAGE_CHANGED=true
    # Signal parent shell (background jobs can't set parent vars)
    echo "1" > "$SERVICE_DIR/.image-changed"
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
    configs-push) step_configs_push ;;
    health)   step_health ;;
    all)      step_build; step_docs; step_secrets ;;
    ship)
        # Runner: where to build Docker images (auto, local, oci-apps, gha)
        RUNNER="${2:-auto}"

        # Special cases: wrangler/terraform have their own flow
        if [ "$WRANGLER_DEPLOY" = "true" ]; then
            step_build; step_secrets; step_wrangler; break
        fi
        if [ "$TERRAFORM_DEPLOY" = "true" ]; then
            step_build; step_secrets; step_terraform; break
        fi

        # ── Phase 1: BUILD (sequential — nix build produces dist/) ──
        rm -f "$SERVICE_DIR/.image-changed"
        step_build

        # ── Phase 2: 4 PARALLEL JOBS (docker + configs + compose-build + secrets) ──
        log "═══ Parallel: docker + configs-push + compose-build + secrets ═══"

        # Job 1: Standalone Dockerfile → GHCR (if src/Dockerfile exists)
        step_docker &
        PID_DOCKER=$!

        # Job 2: Configs image → GHCR (no secrets)
        step_configs_push &
        PID_CONFIGS=$!

        # Job 3: Service image → GHCR (if dockerfile_inline)
        step_compose_build &
        PID_IMAGE=$!

        # Job 4: Secrets decrypt
        step_secrets &
        PID_SECRETS=$!

        # Wait for all 4
        FAIL=0
        wait $PID_DOCKER   || { log_warn "docker build failed"; FAIL=$((FAIL+1)); }
        wait $PID_CONFIGS  || { log_warn "configs-push failed"; FAIL=$((FAIL+1)); }
        wait $PID_IMAGE    || { log_warn "compose-build failed"; FAIL=$((FAIL+1)); }
        wait $PID_SECRETS  || { log_error "secrets failed"; FAIL=$((FAIL+1)); }
        [ $FAIL -gt 1 ] && { log_error "Too many parallel jobs failed ($FAIL/3)"; exit 1; }

        log "═══ Parallel jobs done ═══"

        # Read image-changed flag from background step_compose_build (subshell can't set parent vars)
        if [ -f "$SERVICE_DIR/.image-changed" ]; then
            DOCKER_IMAGE_CHANGED=true
            rm -f "$SERVICE_DIR/.image-changed"
        fi
        # Read image-changed flag from background step_docker (subshell writes file)
        if [ -f "$SERVICE_DIR/.docker-src-hash-new" ]; then
            DOCKER_IMAGE_CHANGED=true
        fi

        # ── Phase 3: DEPLOY TO VM (configs image + secrets via scp) ──
        # Skip if unchanged
        NEW_HASH=$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
        if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
            OLD_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/.dist-hash' 2>/dev/null" 2>/dev/null || true)
        else
            OLD_HASH=$(cat "$SERVICE_DIR/.dist-hash" 2>/dev/null || true)
        fi
        if [ "$OLD_HASH" = "$NEW_HASH" ] && [ -n "$NEW_HASH" ] && [ -z "$DOCKER_IMAGE_CHANGED" ] && [ -z "$FORCE_DEPLOY" ]; then
            log "Config unchanged, no image rebuild — skipping deploy+compose"
        else
            step_deploy
            step_compose
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
