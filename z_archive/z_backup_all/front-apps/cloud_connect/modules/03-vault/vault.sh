#!/usr/bin/env bash
#
# Cloud Connect - Vault Module
#
# Load and manage personal vault
#
# Usage:
#   cloud vault load /path/to/vault
#   cloud vault status
#   cloud vault unload
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

VAULT_MOUNT="/vault"
VAULT_MARKER="$VAULT_MOUNT/.vault"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Vault Module${NC}

${BOLD}USAGE:${NC}
    cloud vault <command> [options]

${BOLD}COMMANDS:${NC}
    load <path>     Load vault from path
    status          Show vault status
    unload          Unload vault

${BOLD}VAULT STRUCTURE:${NC}
    vault/
    ├── ssh/            SSH keys
    ├── wireguard/      WireGuard configs
    ├── rclone/         rclone config
    ├── git/            Git config
    ├── shell/          Shell configs
    └── apps/           App configs

${BOLD}EXAMPLES:${NC}
    cloud vault load /media/usb/my-vault
    cloud vault load ~/vault
    cloud vault status

EOF
}

load_vault() {
    local vault_path="$1"

    if [[ ! -d "$vault_path" ]]; then
        die "Vault not found: $vault_path"
    fi

    log_header "Loading Vault"

    # Verify vault structure
    log_info "Verifying vault structure..."
    local valid=true

    for dir in ssh wireguard; do
        if [[ -d "$vault_path/$dir" ]]; then
            status_ok "Found: $dir/"
        else
            status_skip "Missing: $dir/ (optional)"
        fi
    done

    # Create mount point
    sudo mkdir -p "$VAULT_MOUNT"

    # Bind mount vault (read-only)
    log_info "Mounting vault..."
    sudo mount --bind "$vault_path" "$VAULT_MOUNT"
    sudo mount -o remount,ro "$VAULT_MOUNT"

    # Create marker file with vault path
    echo "$vault_path" | sudo tee "$VAULT_MARKER" > /dev/null

    log_success "Vault loaded!"
    echo ""

    # Show what's available
    echo "Available in vault:"
    for dir in "$VAULT_MOUNT"/*/; do
        if [[ -d "$dir" ]]; then
            echo "  ${GREEN}✓${NC} $(basename "$dir")/"
        fi
    done
    echo ""

    echo "Next steps:"
    if [[ -d "$VAULT_MOUNT/wireguard" ]]; then
        echo "  ${CYAN}cloud vpn up${NC}      - Connect WireGuard"
    fi
    if [[ -d "$VAULT_MOUNT/ssh" ]]; then
        echo "  ${CYAN}cloud ssh setup${NC}   - Setup SSH keys"
    fi
    if [[ -d "$VAULT_MOUNT/rclone" ]]; then
        echo "  ${CYAN}cloud mount up${NC}    - Mount cloud storage"
    fi
    echo ""
}

unload_vault() {
    if [[ ! -f "$VAULT_MARKER" ]]; then
        log_warn "No vault loaded"
        return
    fi

    log_info "Unloading vault..."

    # Unmount
    sudo umount "$VAULT_MOUNT" 2>/dev/null || true
    sudo rm -f "$VAULT_MARKER"

    log_success "Vault unloaded"
}

show_status() {
    log_header "Vault Status"

    if [[ -f "$VAULT_MARKER" ]]; then
        local vault_path
        vault_path=$(cat "$VAULT_MARKER")
        status_ok "Vault: Loaded"
        echo "  Path: $vault_path"
        echo ""
        echo "Contents:"
        for dir in "$VAULT_MOUNT"/*/; do
            if [[ -d "$dir" ]]; then
                local count
                count=$(find "$dir" -type f | wc -l)
                echo "  $(basename "$dir")/: $count files"
            fi
        done
    else
        status_skip "Vault: Not loaded"
        echo ""
        echo "Load with: ${CYAN}cloud vault load /path/to/vault${NC}"
    fi
    echo ""
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            ;;
        load)
            if [[ -z "${2:-}" ]]; then
                die "Specify vault path: cloud vault load /path/to/vault"
            fi
            load_vault "$2"
            ;;
        unload)
            unload_vault
            ;;
        status)
            show_status
            ;;
        *)
            log_error "Unknown command: $1"
            exit 1
            ;;
    esac
}

main "$@"
