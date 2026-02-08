#!/usr/bin/env bash
#
# Cloud Connect - Mount Module
#
# Manage FUSE mounts (rclone, sshfs)
#
# Usage:
#   cloud mount up
#   cloud mount down
#   cloud mount list
#   cloud mount status
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

VAULT_MOUNT="/vault"
MOUNT_BASE="$HOME/mnt"
RCLONE_CONFIG="$VAULT_MOUNT/rclone/rclone.conf"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Mount Module${NC}

${BOLD}USAGE:${NC}
    cloud mount <command> [options]

${BOLD}COMMANDS:${NC}
    up [remote]     Mount remotes (all or specific)
    down [remote]   Unmount remotes (all or specific)
    list            List available remotes
    status          Show mount status

${BOLD}PREREQUISITES:${NC}
    - Vault must be loaded with rclone/rclone.conf

${BOLD}EXAMPLES:${NC}
    cloud mount up
    cloud mount up gdrive
    cloud mount down
    cloud mount status

EOF
}

check_vault() {
    if [[ ! -f "$RCLONE_CONFIG" ]]; then
        die "rclone config not found. Load vault first: cloud vault load /path/to/vault"
    fi
}

install_rclone() {
    if ! command -v rclone &>/dev/null; then
        log_info "Installing rclone..."
        sudo pacman -S --noconfirm rclone
    fi

    if ! command -v sshfs &>/dev/null; then
        log_info "Installing sshfs..."
        sudo pacman -S --noconfirm sshfs
    fi
}

get_remotes() {
    rclone --config="$RCLONE_CONFIG" listremotes 2>/dev/null | tr -d ':'
}

mount_remote() {
    local remote="$1"
    local mount_point="$MOUNT_BASE/$remote"

    # Create mount point
    mkdir -p "$mount_point"

    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_warn "$remote already mounted"
        return
    fi

    log_info "Mounting $remote..."

    # Mount with rclone
    rclone mount \
        --config="$RCLONE_CONFIG" \
        --daemon \
        --vfs-cache-mode full \
        --vfs-cache-max-age 1h \
        --dir-cache-time 5m \
        --poll-interval 10s \
        --allow-other \
        "${remote}:" "$mount_point"

    # Wait for mount
    sleep 1

    if mountpoint -q "$mount_point"; then
        status_ok "Mounted: $remote → $mount_point"
    else
        status_fail "Failed to mount: $remote"
    fi
}

unmount_remote() {
    local remote="$1"
    local mount_point="$MOUNT_BASE/$remote"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        log_warn "$remote not mounted"
        return
    fi

    log_info "Unmounting $remote..."
    fusermount -u "$mount_point" || sudo umount "$mount_point"
    status_ok "Unmounted: $remote"
}

mount_up() {
    check_vault
    install_rclone

    log_header "Mounting Remotes"

    local target="${1:-all}"
    local remotes

    if [[ "$target" == "all" ]]; then
        remotes=$(get_remotes)
    else
        remotes="$target"
    fi

    # Create base mount directory
    mkdir -p "$MOUNT_BASE"

    for remote in $remotes; do
        mount_remote "$remote"
    done

    echo ""
    log_success "Mount complete!"
    echo "Access at: ${CYAN}$MOUNT_BASE${NC}"
    echo ""
}

mount_down() {
    log_header "Unmounting Remotes"

    local target="${1:-all}"

    if [[ "$target" == "all" ]]; then
        # Unmount all
        for mount_point in "$MOUNT_BASE"/*/; do
            if [[ -d "$mount_point" ]] && mountpoint -q "$mount_point"; then
                local remote
                remote=$(basename "$mount_point")
                unmount_remote "$remote"
            fi
        done
    else
        unmount_remote "$target"
    fi

    log_success "Unmount complete"
}

list_remotes() {
    check_vault

    log_header "Available Remotes"

    echo ""
    local remotes
    remotes=$(get_remotes)

    if [[ -z "$remotes" ]]; then
        log_warn "No remotes configured"
    else
        for remote in $remotes; do
            local type
            type=$(rclone --config="$RCLONE_CONFIG" config show "$remote" 2>/dev/null | grep "type" | cut -d'=' -f2 | tr -d ' ')
            printf "  ${CYAN}%-20s${NC} %s\n" "$remote" "($type)"
        done
    fi

    echo ""
}

show_status() {
    log_header "Mount Status"

    # Check if any mounts exist
    local has_mounts=false

    if [[ -d "$MOUNT_BASE" ]]; then
        for mount_point in "$MOUNT_BASE"/*/; do
            if [[ -d "$mount_point" ]]; then
                local remote
                remote=$(basename "$mount_point")
                has_mounts=true

                if mountpoint -q "$mount_point"; then
                    status_ok "$remote: Mounted at $mount_point"

                    # Show usage
                    local usage
                    usage=$(df -h "$mount_point" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')
                    echo "      Usage: $usage"
                else
                    status_skip "$remote: Not mounted"
                fi
            fi
        done
    fi

    if [[ "$has_mounts" == false ]]; then
        echo "  No mounts configured"
        echo ""
        echo "  Mount with: ${CYAN}cloud mount up${NC}"
    fi

    echo ""
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            ;;
        up)
            mount_up "${2:-all}"
            ;;
        down)
            mount_down "${2:-all}"
            ;;
        list)
            list_remotes
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
