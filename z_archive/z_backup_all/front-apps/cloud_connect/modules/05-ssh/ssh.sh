#!/usr/bin/env bash
#
# Cloud Connect - SSH Module
#
# Manage SSH connections
#
# Usage:
#   cloud ssh setup
#   cloud ssh to <vm>
#   cloud ssh list
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

VAULT_MOUNT="/vault"
SSH_DIR="$HOME/.ssh"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - SSH Module${NC}

${BOLD}USAGE:${NC}
    cloud ssh <command> [options]

${BOLD}COMMANDS:${NC}
    setup       Setup SSH keys from vault
    to <vm>     SSH to a VM
    list        List configured VMs
    agent       Start SSH agent and add keys

${BOLD}PREREQUISITES:${NC}
    - Vault must be loaded with ssh/ directory

${BOLD}EXAMPLES:${NC}
    cloud ssh setup
    cloud ssh list
    cloud ssh to gcp

EOF
}

check_vault() {
    if [[ ! -d "$VAULT_MOUNT/ssh" ]]; then
        die "SSH keys not found. Load vault first: cloud vault load /path/to/vault"
    fi
}

setup_ssh() {
    check_vault

    log_header "Setting up SSH"

    # Create .ssh directory
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Copy keys from vault
    log_info "Copying SSH keys..."

    for key in "$VAULT_MOUNT/ssh"/*; do
        if [[ -f "$key" ]]; then
            local keyname
            keyname=$(basename "$key")
            cp "$key" "$SSH_DIR/$keyname"

            # Set permissions
            if [[ "$keyname" == *.pub ]]; then
                chmod 644 "$SSH_DIR/$keyname"
            else
                chmod 600 "$SSH_DIR/$keyname"
            fi

            status_ok "Copied: $keyname"
        fi
    done

    # Copy SSH config if exists
    if [[ -f "$VAULT_MOUNT/ssh/config" ]]; then
        cp "$VAULT_MOUNT/ssh/config" "$SSH_DIR/config"
        chmod 600 "$SSH_DIR/config"
        status_ok "Copied: config"
    fi

    # Start SSH agent and add keys
    log_info "Starting SSH agent..."
    eval "$(ssh-agent -s)"

    for key in "$SSH_DIR"/id_*; do
        if [[ -f "$key" ]] && [[ ! "$key" == *.pub ]]; then
            ssh-add "$key" 2>/dev/null || true
        fi
    done

    log_success "SSH setup complete!"
    echo ""

    # Show configured hosts
    if [[ -f "$SSH_DIR/config" ]]; then
        echo "Configured hosts:"
        grep -E "^Host " "$SSH_DIR/config" | awk '{print "  " $2}'
        echo ""
    fi
}

start_agent() {
    log_info "Starting SSH agent..."

    # Kill existing agent
    pkill ssh-agent 2>/dev/null || true

    # Start new agent
    eval "$(ssh-agent -s)"

    # Add keys
    for key in "$SSH_DIR"/id_*; do
        if [[ -f "$key" ]] && [[ ! "$key" == *.pub ]]; then
            ssh-add "$key" 2>/dev/null && status_ok "Added: $(basename "$key")"
        fi
    done

    log_success "SSH agent started"
}

ssh_to() {
    local target="$1"

    if [[ ! -f "$SSH_DIR/config" ]]; then
        die "No SSH config found. Run: cloud ssh setup"
    fi

    # Check if host exists in config
    if ! grep -qE "^Host $target" "$SSH_DIR/config"; then
        die "Host '$target' not found in SSH config"
    fi

    log_info "Connecting to $target..."
    ssh "$target"
}

list_hosts() {
    log_header "SSH Hosts"

    if [[ ! -f "$SSH_DIR/config" ]]; then
        log_warn "No SSH config found"
        echo "Run: ${CYAN}cloud ssh setup${NC}"
        return
    fi

    echo ""
    echo "Available hosts:"

    # Parse SSH config for hosts
    while IFS= read -r line; do
        if [[ "$line" =~ ^Host\ (.+) ]]; then
            local host="${BASH_REMATCH[1]}"
            if [[ "$host" != "*" ]]; then
                echo "  ${CYAN}$host${NC}"
            fi
        fi
    done < "$SSH_DIR/config"

    echo ""
    echo "Connect with: ${CYAN}cloud ssh to <host>${NC}"
    echo ""
}

show_status() {
    log_header "SSH Status"

    # Check keys
    if [[ -d "$SSH_DIR" ]]; then
        local key_count
        key_count=$(find "$SSH_DIR" -name "id_*" -not -name "*.pub" | wc -l)
        if [[ $key_count -gt 0 ]]; then
            status_ok "Keys: $key_count private keys"
        else
            status_skip "Keys: None found"
        fi
    else
        status_skip "SSH directory: Not created"
    fi

    # Check agent
    if ssh-add -l &>/dev/null; then
        local loaded
        loaded=$(ssh-add -l | wc -l)
        status_ok "Agent: Running ($loaded keys loaded)"
    else
        status_skip "Agent: Not running"
    fi

    # Check config
    if [[ -f "$SSH_DIR/config" ]]; then
        local hosts
        hosts=$(grep -c "^Host " "$SSH_DIR/config" 2>/dev/null || echo 0)
        status_ok "Config: $hosts hosts configured"
    else
        status_skip "Config: Not found"
    fi

    echo ""
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            ;;
        setup)
            setup_ssh
            ;;
        to|connect)
            if [[ -z "${2:-}" ]]; then
                die "Specify host: cloud ssh to <host>"
            fi
            ssh_to "$2"
            ;;
        list)
            list_hosts
            ;;
        agent)
            start_agent
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
