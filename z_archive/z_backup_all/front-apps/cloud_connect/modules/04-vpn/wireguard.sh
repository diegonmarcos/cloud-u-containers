#!/usr/bin/env bash
#
# Cloud Connect - VPN Module
#
# Manage WireGuard VPN connection
#
# Usage:
#   cloud vpn up
#   cloud vpn down
#   cloud vpn status
#   cloud vpn split   (split tunnel mode)
#   cloud vpn full    (full tunnel mode)
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

VAULT_MOUNT="/vault"
WG_CONFIG_DIR="$VAULT_MOUNT/wireguard"
WG_INTERFACE="${WG_INTERFACE:-wg0}"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - VPN Module${NC}

${BOLD}USAGE:${NC}
    cloud vpn <command>

${BOLD}COMMANDS:${NC}
    up          Connect WireGuard VPN
    down        Disconnect VPN
    status      Show VPN status
    split       Enable split tunnel (cloud via WG, public via ProtonVPN)
    full        Enable full tunnel (all traffic via WG)

${BOLD}PREREQUISITES:${NC}
    - Vault must be loaded with wireguard/ directory
    - wireguard/wg0.conf must exist

${BOLD}EXAMPLES:${NC}
    cloud vault load /path/to/vault
    cloud vpn up
    cloud vpn status

EOF
}

check_vault() {
    if [[ ! -d "$WG_CONFIG_DIR" ]]; then
        die "WireGuard config not found. Load vault first: cloud vault load /path/to/vault"
    fi

    if [[ ! -f "$WG_CONFIG_DIR/$WG_INTERFACE.conf" ]]; then
        die "Config not found: $WG_CONFIG_DIR/$WG_INTERFACE.conf"
    fi
}

vpn_up() {
    check_vault

    log_info "Connecting WireGuard VPN..."

    # Copy config (wg-quick needs writable config)
    sudo cp "$WG_CONFIG_DIR/$WG_INTERFACE.conf" /etc/wireguard/
    sudo chmod 600 /etc/wireguard/$WG_INTERFACE.conf

    # Bring up interface
    sudo wg-quick up $WG_INTERFACE

    log_success "VPN connected!"
    vpn_status
}

vpn_down() {
    log_info "Disconnecting VPN..."

    if sudo wg show $WG_INTERFACE &>/dev/null; then
        sudo wg-quick down $WG_INTERFACE
        log_success "VPN disconnected"
    else
        log_warn "VPN not connected"
    fi
}

vpn_status() {
    log_header "VPN Status"

    if sudo wg show $WG_INTERFACE &>/dev/null; then
        status_ok "WireGuard: Connected"
        echo ""

        # Show interface details
        sudo wg show $WG_INTERFACE

        echo ""

        # Show endpoint
        local endpoint
        endpoint=$(sudo wg show $WG_INTERFACE endpoints | awk '{print $2}' | head -1)
        echo "Endpoint: $endpoint"

        # Show transfer stats
        local rx tx
        rx=$(sudo wg show $WG_INTERFACE transfer | awk '{print $2}' | head -1)
        tx=$(sudo wg show $WG_INTERFACE transfer | awk '{print $3}' | head -1)
        echo "Transfer: RX $rx / TX $tx"

    else
        status_skip "WireGuard: Not connected"
        echo ""
        echo "Connect with: ${CYAN}cloud vpn up${NC}"
    fi

    # ProtonVPN status
    echo ""
    if protonvpn-cli status 2>/dev/null | grep -q "Connected"; then
        status_ok "ProtonVPN: Connected"
    else
        status_skip "ProtonVPN: Not connected"
    fi

    echo ""
}

enable_split_tunnel() {
    log_info "Enabling split tunnel mode..."

    # This requires both WireGuard and ProtonVPN
    # WireGuard handles cloud traffic, ProtonVPN handles public traffic

    check_vault

    # Read allowed IPs from WireGuard config
    local allowed_ips
    allowed_ips=$(grep -E "^AllowedIPs" "$WG_CONFIG_DIR/$WG_INTERFACE.conf" | cut -d'=' -f2 | tr -d ' ')

    if [[ -z "$allowed_ips" ]]; then
        die "No AllowedIPs found in WireGuard config"
    fi

    log_info "WireGuard will handle: $allowed_ips"
    log_info "ProtonVPN will handle: everything else"

    # Bring up WireGuard with limited routes
    vpn_up

    # Connect ProtonVPN
    log_info "Connecting ProtonVPN..."
    protonvpn-cli connect --fastest || log_warn "ProtonVPN connection failed"

    log_success "Split tunnel enabled!"
}

enable_full_tunnel() {
    log_info "Enabling full tunnel mode..."

    # Disconnect ProtonVPN if connected
    protonvpn-cli disconnect 2>/dev/null || true

    # Connect WireGuard with full routing
    check_vault

    # Modify config to route all traffic
    sudo cp "$WG_CONFIG_DIR/$WG_INTERFACE.conf" /etc/wireguard/
    sudo sed -i 's/AllowedIPs = .*/AllowedIPs = 0.0.0.0\/0/' /etc/wireguard/$WG_INTERFACE.conf

    sudo wg-quick up $WG_INTERFACE

    log_success "Full tunnel enabled (all traffic via WireGuard)"
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            ;;
        up|connect)
            vpn_up
            ;;
        down|disconnect)
            vpn_down
            ;;
        status)
            vpn_status
            ;;
        split)
            enable_split_tunnel
            ;;
        full)
            enable_full_tunnel
            ;;
        *)
            log_error "Unknown command: $1"
            exit 1
            ;;
    esac
}

main "$@"
