#!/bin/sh
# bb-sec_mcp-server-skills build script
# Deploys SKILL.md to ~/.claude/skills/personal-cloud-manager/
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_SRC="$SERVICE_DIR/SKILL.md"
SKILL_DEST="$HOME/.claude/skills/personal-cloud-manager"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

step_build() {
    log "Nothing to build (TypeScript runs via tsx)"
}

step_install() {
    log "Installing npm dependencies..."
    cd "$SERVICE_DIR" && npm install
}

step_deploy() {
    log "Deploying SKILL.md to $SKILL_DEST/"
    mkdir -p "$SKILL_DEST"
    cp "$SKILL_SRC" "$SKILL_DEST/SKILL.md"
    log "Deployed SKILL.md"
}

step_register() {
    log "Registering MCP server with Claude Code..."
    claude mcp add cloud-infra -- npx tsx "$SERVICE_DIR/src/index.ts"
    log "Registered cloud-infra MCP server"
}

step_clean() {
    log "Removing deployed skill..."
    rm -rf "$SKILL_DEST"
    log "Cleaned"
}

step_all() {
    step_install
    step_deploy
    step_register
}

case "${1:-all}" in
    build)    step_build ;;
    install)  step_install ;;
    deploy)   step_deploy ;;
    register) step_register ;;
    clean)    step_clean ;;
    all)      step_all ;;
    *)        echo "Usage: $0 {build|install|deploy|register|clean|all}"; exit 1 ;;
esac
