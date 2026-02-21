#!/bin/sh
# Per-service build script: src/ → dist/ → docker build → local deploy
# Containerized MCP tool — nix flake builds dist/, Docker packages runtime
# Pipeline: build (nix + docker) → secrets → deploy (no-op) → compose (register MCP)
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR" | sed 's/^[a-z]*-[a-z]*_//')"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"

CONTAINER_IMAGE="cloud-infra-mcp:latest"

# Deploy config from build.json (node primary, python3 fallback)
get_config() {
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v=$( echo "'$1'.split('.')" | sed "s/'/\"/g" ); r=c; exec('for k in v: r=r.get(k,{})'); print(r if isinstance(r,str) else '',end='')"
    fi
}

SKILL_DEST="$(eval echo "$(get_config deploy.skill_dest)")"
MCP_NAME="$(get_config deploy.mcp_name)"

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step 1: Build nix flake → dist/ + Docker image ──────────────────────
step_build() {
    log "Building nix flake → dist/"
    cd "$SRC_DIR"

    nix build --out-link "$SERVICE_DIR/.result"

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    # Copy package.json + tsconfig.json into dist/ (outside src/, needed by Dockerfile)
    log "Copying package.json + tsconfig.json → dist/"
    cp "$SERVICE_DIR/package.json" "$DIST_DIR/package.json"
    cp "$SERVICE_DIR/tsconfig.json" "$DIST_DIR/tsconfig.json"

    # npm install + compile TypeScript → dist/ (JS for direct node execution)
    log "Installing npm dependencies..."
    cd "$SERVICE_DIR" && npm install

    log "Compiling TypeScript → dist/ (JS)..."
    cd "$SERVICE_DIR" && npx tsc

    log "Compiled JS files:"
    find "$DIST_DIR" -name '*.js' -not -path '*/src/*' | sed "s|$DIST_DIR/|  |"

    # Build container image from dist/ (podman on Termux, docker fallback)
    # On Android/Termux, rootless podman can't build (no user_namespaces) — falls back to npx tsx
    if command -v podman >/dev/null 2>&1; then
        log "Building container image (podman): $CONTAINER_IMAGE"
        if ! podman build -t "$CONTAINER_IMAGE" "$DIST_DIR" 2>&1; then
            log "WARNING: podman build failed (likely Termux kernel limitation) — MCP will use npx tsx"
        fi
    elif command -v docker >/dev/null 2>&1; then
        log "Building container image (docker): $CONTAINER_IMAGE"
        docker build -t "$CONTAINER_IMAGE" "$DIST_DIR"
    else
        log "WARNING: No container runtime — skipping image build (dist/ ready for podman/docker build)"
    fi

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


# ── Step 2: Decrypt secrets → .secrets ────────────────────────────────
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

# ── Step 3: Deploy (no-op — SKILL.md migrated to MCP prompts v2.3.1) ─
step_deploy() {
    log "SKILL.md no longer deployed — content migrated to MCP prompts (cloud-architect, frontend-developer, debug-ops, crawlee-scraping)"
    # Clean up old deployed skill file if it exists
    if [ -n "$SKILL_DEST" ] && [ -f "$SKILL_DEST/SKILL.md" ]; then
        rm -f "$SKILL_DEST/SKILL.md"
        rmdir "$SKILL_DEST" 2>/dev/null || true
        log "Cleaned up old $SKILL_DEST/SKILL.md"
    fi
}

# ── Step 4: Register MCP with Claude Code (docker run) ────────────────
step_compose() {
    [ -z "$MCP_NAME" ] && { log "ERROR: deploy.mcp_name not set in build.json"; return 1; }

    log "Registering MCP server '$MCP_NAME' with Claude Code..."

    if [ -n "$CLAUDECODE" ]; then
        log "WARNING: Inside Claude Code session — cannot register MCP (nested sessions blocked)"
        log "Run manually after exiting: $0 compose"
        return 0
    fi

    # Register MCP: check if container image exists, otherwise npx tsx fallback
    HAS_IMAGE=false
    if command -v podman >/dev/null 2>&1 && podman image exists "$CONTAINER_IMAGE" 2>/dev/null; then
        HAS_IMAGE=true
        claude mcp add "$MCP_NAME" -- \
            podman run -i --rm \
            -v "$HOME/git:$HOME/git:ro" \
            -v "$HOME/.ssh:$HOME/.ssh:ro" \
            -e "HOME=$HOME" \
            "$CONTAINER_IMAGE"
        log "Registered $MCP_NAME MCP server (podman: $CONTAINER_IMAGE)"
    elif command -v docker >/dev/null 2>&1 && docker image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
        HAS_IMAGE=true
        claude mcp add "$MCP_NAME" -- \
            docker run -i --rm \
            -v "$HOME/git:$HOME/git:ro" \
            -v "$HOME/.ssh:$HOME/.ssh:ro" \
            -e "HOME=$HOME" \
            "$CONTAINER_IMAGE"
        log "Registered $MCP_NAME MCP server (docker: $CONTAINER_IMAGE)"
    fi

    if [ "$HAS_IMAGE" = false ]; then
        claude mcp add "$MCP_NAME" -- npx tsx "$SRC_DIR/index.ts"
        log "Registered $MCP_NAME MCP server (npx tsx — no container image available)"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────
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
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result"; command -v podman >/dev/null 2>&1 && podman rmi "$CONTAINER_IMAGE" 2>/dev/null || command -v docker >/dev/null 2>&1 && docker rmi "$CONTAINER_IMAGE" 2>/dev/null || true; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|docs|secrets|deploy|compose|all|ship|clean]"
        echo "  build    Nix flake → dist/ + Docker image build"
        echo "  secrets  Decrypt secrets → dist/.secrets"
        echo "  deploy   No-op (SKILL.md migrated to MCP prompts)"
        echo "  compose  Register MCP with Claude Code (docker run)"
        echo "  all      build + docs + secrets (default)"
        echo "  ship     build + docs + secrets + deploy + compose"
        echo "  clean    Remove dist/ + Docker image"
        ;;
esac

log "Done."
