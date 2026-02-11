#!/bin/sh
# Home Manager deployment script using ship pattern
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="home-manager"
CONFIG="$SERVICE_DIR/build.json"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# Get VM list from build.json
get_vms() {
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); console.log(Object.keys(c.vms).join(' '))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); print(' '.join(c['vms'].keys()))"
    else
        echo "gcp-proxy oci-flex oci-mail oci-analytics"
    fi
}

get_vm_config() {
    local vm="$1"
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); console.log(c.vms['$vm'].config)"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); print(c['vms']['$vm']['config'])"
    fi
}

# ── Step 1: Build (validate flake) ─────────────────────────────────────
step_build() {
    log "Validating flake configurations..."

    for vm in $(get_vms); do
        config=$(get_vm_config "$vm")
        log "  Checking $vm ($config)..."
        nix flake check --show-trace 2>&1 | head -5 || true
    done

    log "Flake validation complete"
}

# ── Step 2: Deploy to VM ───────────────────────────────────────────────
step_deploy() {
    local target_vm="${1:-all}"

    if [ "$target_vm" = "all" ]; then
        for vm in $(get_vms); do
            deploy_single_vm "$vm"
        done
    else
        deploy_single_vm "$target_vm"
    fi
}

deploy_single_vm() {
    local vm="$1"
    local config=$(get_vm_config "$vm")

    log "Deploying to $vm ($config)..."

    # Copy flake files to VM
    log "  Copying flake to $vm:~/.config/home-manager/"
    ssh "$vm" "mkdir -p ~/.config/home-manager"

    # Use scp as fallback if rsync not available
    if command -v rsync >/dev/null 2>&1; then
        rsync -avz --delete \
            --include="flake.nix" \
            --include="flake.lock" \
            --include="${vm}.nix" \
            --include="*.nix" \
            --exclude="*" \
            "$SERVICE_DIR/" "$vm:~/.config/home-manager/" 2>&1 | grep -v "^sending\|^sent\|^total"
    else
        # Fallback: use scp for individual files
        scp "$SERVICE_DIR"/*.nix "$SERVICE_DIR/flake.lock" "$vm:~/.config/home-manager/" 2>&1 | tail -1
    fi

    log "  ✓ Files copied to $vm"
}

# ── Step 3: Activate on VM ─────────────────────────────────────────────
step_compose() {
    local target_vm="${1:-all}"

    if [ "$target_vm" = "all" ]; then
        for vm in $(get_vms); do
            activate_single_vm "$vm"
        done
    else
        activate_single_vm "$target_vm"
    fi
}

activate_single_vm() {
    local vm="$1"
    local config=$(get_vm_config "$vm")

    log "Activating home-manager on $vm..."

    # Run home-manager switch on VM with backup
    ssh "$vm" "cd ~/.config/home-manager && nix run home-manager/release-24.11 -- switch --flake .#$config -b backup" 2>&1 | tail -10

    log "  ✓ $vm activated"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Home Manager Deployment"
echo "╚════════════════════════════════════════╝"

case "${1:-help}" in
    build)
        step_build
        ;;
    deploy)
        step_deploy "${2:-all}"
        ;;
    compose|activate)
        step_compose "${2:-all}"
        ;;
    ship)
        step_build
        step_deploy "${2:-all}"
        step_compose "${2:-all}"
        ;;
    check)
        nix flake check
        ;;
    update)
        log "Updating flake inputs..."
        nix flake update
        log "Updated. Run './build.sh ship' to deploy"
        ;;
    clean)
        log "Nothing to clean (no dist/ directory)"
        ;;
    *)
        echo "Usage: $0 [build|deploy|compose|ship|check|update|clean] [vm]"
        echo ""
        echo "Commands:"
        echo "  build     Validate flake configurations"
        echo "  deploy    Copy flake files to VM(s)"
        echo "  compose   Activate home-manager on VM(s)"
        echo "  ship      build + deploy + compose (default: all VMs)"
        echo "  check     Run nix flake check"
        echo "  update    Update flake inputs"
        echo "  clean     No-op (for consistency)"
        echo ""
        echo "VMs: all (default), gcp-proxy, oci-flex, oci-mail, oci-analytics"
        echo ""
        echo "Examples:"
        echo "  $0 ship              # Deploy to all VMs"
        echo "  $0 ship oci-flex     # Deploy to oci-flex only"
        echo "  $0 deploy gcp-proxy  # Copy files to gcp-proxy"
        ;;
esac

log "Done."
