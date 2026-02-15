#!/bin/sh
# Deploy home-manager configurations to cloud VMs
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

deploy_vm() {
    local vm="$1"
    local user=""
    local config=""

    case "$vm" in
        gcp-proxy)
            user="diego"
            config="diego@gcp-proxy"
            ;;
        oci-flex-0)
            user="ubuntu"
            config="ubuntu@oci-flex-0"
            ;;
        oci-flex-1)
            user="ubuntu"
            config="ubuntu@oci-flex-1"
            ;;
        oci-mail)
            user="ubuntu"
            config="ubuntu@oci-mail"
            ;;
        oci-analytics)
            user="ubuntu"
            config="ubuntu@oci-analytics"
            ;;
        *)
            echo "Unknown VM: $vm"
            echo "Valid VMs: gcp-proxy, oci-flex-0, oci-flex-1, oci-mail, oci-analytics"
            return 1
            ;;
    esac

    log "Deploying to $vm ($user)..."

    # Copy flake to VM
    log "  Copying flake files to $vm..."
    ssh "$vm" "mkdir -p ~/.config/home-manager"
    rsync -avz --delete \
        --include="flake.nix" \
        --include="flake.lock" \
        --include="${vm}.nix" \
        --exclude="*" \
        ./ "$vm:~/.config/home-manager/"

    # Deploy on VM
    log "  Running home-manager switch on $vm..."
    ssh "$vm" "cd ~/.config/home-manager && nix run home-manager/release-24.11 -- switch --flake .#$config"

    log "  ✓ $vm deployed successfully"
}

case "${1:-all}" in
    all)
        deploy_vm "gcp-proxy"
        deploy_vm "oci-flex-0"
        deploy_vm "oci-flex-1"
        deploy_vm "oci-mail"
        deploy_vm "oci-analytics"
        log "All VMs deployed"
        ;;
    gcp-proxy|oci-flex-0|oci-flex-1|oci-mail|oci-analytics)
        deploy_vm "$1"
        ;;
    *)
        echo "Usage: $0 [all|gcp-proxy|oci-flex-0|oci-flex-1|oci-mail|oci-analytics]"
        exit 1
        ;;
esac

log "Done."
