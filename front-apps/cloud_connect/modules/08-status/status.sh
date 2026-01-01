#!/usr/bin/env bash
#
# Cloud Connect - Status Module
#
# Show system status and health
#
# Usage:
#   cloud status
#   cloud status health
#   cloud status topology
#   cloud status vms
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

VAULT_MOUNT="/vault"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Status Module${NC}

${BOLD}USAGE:${NC}
    cloud status [command]

${BOLD}COMMANDS:${NC}
    (none)      Show overview
    health      Run health checks
    topology    Show network topology
    vms         Show VM status (requires vault)

${BOLD}EXAMPLES:${NC}
    cloud status
    cloud status health
    cloud status topology

EOF
}

show_overview() {
    log_header "Cloud Connect Status"

    # Vault
    echo ""
    echo "${BOLD}Vault${NC}"
    if [[ -f "$VAULT_MOUNT/.vault" ]]; then
        status_ok "Loaded: $(cat $VAULT_MOUNT/.vault)"
    else
        status_skip "Not loaded"
    fi

    # VPN
    echo ""
    echo "${BOLD}VPN${NC}"
    if sudo wg show wg0 &>/dev/null 2>&1; then
        status_ok "WireGuard: Connected"
    else
        status_skip "WireGuard: Not connected"
    fi

    if protonvpn-cli status 2>/dev/null | grep -q "Connected"; then
        status_ok "ProtonVPN: Connected"
    else
        status_skip "ProtonVPN: Not connected"
    fi

    # DNS
    echo ""
    echo "${BOLD}DNS${NC}"
    if pgrep -f cloudflared &>/dev/null; then
        status_ok "Encrypted DNS: Active (cloudflared)"
    else
        status_skip "Encrypted DNS: Not running"
    fi

    # Mounts
    echo ""
    echo "${BOLD}Mounts${NC}"
    local mount_count=0
    if [[ -d ~/mnt ]]; then
        for mp in ~/mnt/*/; do
            if [[ -d "$mp" ]] && mountpoint -q "$mp" 2>/dev/null; then
                mount_count=$((mount_count + 1))
            fi
        done
    fi
    if [[ $mount_count -gt 0 ]]; then
        status_ok "FUSE mounts: $mount_count active"
    else
        status_skip "FUSE mounts: None"
    fi

    # Resources
    echo ""
    echo "${BOLD}Resources${NC}"
    local mem_used mem_total mem_percent
    read -r mem_used mem_total mem_percent <<< $(free -h | awk '/Mem:/ {print $3, $2, int($3/$2*100)}')
    echo "  Memory: $mem_used / $mem_total ($mem_percent%)"

    local cpu_cores cpu_load
    cpu_cores=$(nproc)
    cpu_load=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    echo "  CPU: $cpu_load load avg ($cpu_cores cores)"

    echo ""
}

run_health_checks() {
    log_header "Health Checks"

    local passed=0
    local failed=0

    echo ""

    # Check 1: Internet connectivity
    echo -n "Internet connectivity... "
    if ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        passed=$((passed + 1))
    else
        echo -e "${RED}FAIL${NC}"
        failed=$((failed + 1))
    fi

    # Check 2: DNS resolution
    echo -n "DNS resolution... "
    if host google.com &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        passed=$((passed + 1))
    else
        echo -e "${RED}FAIL${NC}"
        failed=$((failed + 1))
    fi

    # Check 3: Encrypted DNS
    echo -n "Encrypted DNS... "
    if pgrep -f cloudflared &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        passed=$((passed + 1))
    else
        echo -e "${YELLOW}WARN${NC} (not running)"
        failed=$((failed + 1))
    fi

    # Check 4: VPN (at least one)
    echo -n "VPN connection... "
    if sudo wg show wg0 &>/dev/null 2>&1 || protonvpn-cli status 2>/dev/null | grep -q "Connected"; then
        echo -e "${GREEN}OK${NC}"
        passed=$((passed + 1))
    else
        echo -e "${YELLOW}WARN${NC} (not connected)"
    fi

    # Check 5: Disk space
    echo -n "Disk space... "
    local disk_percent
    disk_percent=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
    if [[ $disk_percent -lt 90 ]]; then
        echo -e "${GREEN}OK${NC} ($disk_percent% used)"
        passed=$((passed + 1))
    else
        echo -e "${RED}WARN${NC} ($disk_percent% used)"
        failed=$((failed + 1))
    fi

    # Check 6: Memory
    echo -n "Memory... "
    local mem_percent
    mem_percent=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
    if [[ $mem_percent -lt 90 ]]; then
        echo -e "${GREEN}OK${NC} ($mem_percent% used)"
        passed=$((passed + 1))
    else
        echo -e "${YELLOW}WARN${NC} ($mem_percent% used)"
    fi

    echo ""
    echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
    echo ""
}

show_topology() {
    log_header "Network Topology"

    echo ""
    echo "                              CONTAINER"
    echo "                                  │"

    # Check VPNs
    local has_wg=false has_proton=false

    if sudo wg show wg0 &>/dev/null 2>&1; then
        has_wg=true
    fi

    if protonvpn-cli status 2>/dev/null | grep -q "Connected"; then
        has_proton=true
    fi

    if $has_wg && $has_proton; then
        echo "                  ┌───────────────┼───────────────┐"
        echo "                  │                               │"
        echo "                  ▼                               ▼"
        echo "         ┌─────────────────┐             ┌─────────────────┐"
        echo "         │    WireGuard    │             │   ProtonVPN     │"
        echo "         │  (personal VPN) │             │  (anonymous)    │"
        echo "         └────────┬────────┘             └────────┬────────┘"
        echo "                  │                               │"
        echo "                  ▼                               ▼"
        echo "         ┌─────────────────┐             ┌─────────────────┐"
        echo "         │  CLOUD INFRA    │             │    INTERNET     │"
        echo "         │  (your VMs)     │             │   (anonymous)   │"
        echo "         └─────────────────┘             └─────────────────┘"
        echo ""
        echo "  Mode: ${GREEN}Split Tunnel${NC}"
    elif $has_wg; then
        echo "                  │"
        echo "                  ▼"
        echo "         ┌─────────────────┐"
        echo "         │    WireGuard    │"
        echo "         └────────┬────────┘"
        echo "                  │"
        echo "                  ▼"
        echo "         ┌─────────────────┐"
        echo "         │  CLOUD + WEB    │"
        echo "         └─────────────────┘"
        echo ""
        echo "  Mode: ${YELLOW}Full WireGuard${NC}"
    elif $has_proton; then
        echo "                  │"
        echo "                  ▼"
        echo "         ┌─────────────────┐"
        echo "         │   ProtonVPN     │"
        echo "         │   (anonymous)   │"
        echo "         └────────┬────────┘"
        echo "                  │"
        echo "                  ▼"
        echo "         ┌─────────────────┐"
        echo "         │    INTERNET     │"
        echo "         │   (anonymous)   │"
        echo "         └─────────────────┘"
        echo ""
        echo "  Mode: ${CYAN}Anonymous${NC}"
    else
        echo "                  │"
        echo "                  ▼"
        echo "         ┌─────────────────┐"
        echo "         │    INTERNET     │"
        echo "         │   (DIRECT!)     │"
        echo "         └─────────────────┘"
        echo ""
        echo "  Mode: ${RED}No VPN!${NC}"
    fi

    echo ""
}

show_vms() {
    log_header "VM Status"

    if [[ ! -f "$VAULT_MOUNT/.vault" ]]; then
        log_warn "Vault not loaded. VM info not available."
        echo "Load vault to see VM status: ${CYAN}cloud vault load /path/to/vault${NC}"
        return
    fi

    # Check for VM config in vault
    if [[ -f "$VAULT_MOUNT/vms.json" ]] || [[ -f "$VAULT_MOUNT/ssh/config" ]]; then
        echo ""
        echo "Configured VMs:"

        if [[ -f ~/.ssh/config ]]; then
            grep -E "^Host " ~/.ssh/config | while read -r line; do
                local host
                host=$(echo "$line" | awk '{print $2}')

                # Try to ping
                if ping -c 1 -W 1 "$host" &>/dev/null 2>&1; then
                    status_ok "$host: Reachable"
                else
                    status_skip "$host: Unreachable"
                fi
            done
        fi
    else
        echo "No VM configuration found in vault"
    fi

    echo ""
}

main() {
    case "${1:-overview}" in
        -h|--help)
            show_help
            ;;
        overview|"")
            show_overview
            ;;
        health)
            run_health_checks
            ;;
        topology)
            show_topology
            ;;
        vms)
            show_vms
            ;;
        *)
            log_error "Unknown command: $1"
            exit 1
            ;;
    esac
}

main "$@"
