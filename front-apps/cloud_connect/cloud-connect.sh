#!/usr/bin/env bash
#
# Cloud Connect - Portable Entry Point
#
# Creates an anonymous isolated environment with:
# - ProtonVPN (free tier)
# - Encrypted DNS (DoH/DoT)
# - Brave browser
#
# Requirements: Linux + Docker + Shell
#
# Usage:
#   ./cloud-connect.sh              # Create and enter container
#   ./cloud-connect.sh stop         # Stop container
#   ./cloud-connect.sh tools ...    # Run tools module
#   ./cloud-connect.sh --help       # Show help
#

set -euo pipefail

# Script directory (works even if symlinked)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/docker.sh"

# Version
VERSION="2.0.0"

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

CONTAINER_NAME="${CLOUD_CONTAINER_NAME:-cloud-connect}"
IMAGE_NAME="${CLOUD_IMAGE_NAME:-cloud-connect}"
IMAGE_TAG="${CLOUD_IMAGE_TAG:-latest}"
COMPOSE_FILE="$SCRIPT_DIR/modules/00-base/docker-compose.yml"

# ═══════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════

show_help() {
    cat << EOF
${BOLD}Cloud Connect${NC} v$VERSION - Anonymous Isolated Environment

${BOLD}USAGE:${NC}
    ./cloud-connect.sh [command] [options]

${BOLD}CONTAINER COMMANDS:${NC}
    start, up       Create and start container (default)
    enter, shell    Enter container shell
    stop, down      Stop container
    destroy         Remove container completely
    status          Show container status
    logs            Show container logs

${BOLD}MODULE COMMANDS:${NC}
    tools           Development tools (python, node, rust, go)
    desktop         KDE Plasma desktop
    vault           Load personal vault
    vpn             WireGuard VPN connection
    ssh             SSH connections
    mount           FUSE mounts
    config          Apply personal configs

${BOLD}UTILITY COMMANDS:${NC}
    status          System status and health
    export          Export data and reports

${BOLD}OPTIONS:${NC}
    -h, --help      Show this help
    -v, --version   Show version
    --debug         Enable debug mode

${BOLD}EXAMPLES:${NC}
    ./cloud-connect.sh                  # Start anonymous environment
    ./cloud-connect.sh tools install    # Install dev tools
    ./cloud-connect.sh vault load ~/vault  # Load personal vault
    ./cloud-connect.sh vpn up           # Connect VPN
    ./cloud-connect.sh stop             # Stop container

${BOLD}STEP-BY-STEP FLOW:${NC}
    1. ${GREEN}Anonymous:${NC} ./cloud-connect.sh
       → Container with ProtonVPN + encrypted DNS + Brave

    2. ${YELLOW}Tools:${NC} cloud tools install python node rust
       → Add development stack

    3. ${CYAN}Personal:${NC} cloud vault load /path/to/vault
       → Load personal configs, VPN, SSH keys

EOF
}

show_version() {
    echo "Cloud Connect v$VERSION"
}

# ═══════════════════════════════════════════════════════════════════════════
# CONTAINER MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════

create_container() {
    require_docker

    log_header "Creating Anonymous Environment"

    # Calculate resource limits
    local cpu_limit mem_limit swap_limit
    cpu_limit=$(get_cpu_limit)
    mem_limit=$(get_mem_limit)
    swap_limit=$(get_swap_limit)

    log_info "Resource limits (90% of system):"
    echo "  CPU:    $cpu_limit cores"
    echo "  Memory: $mem_limit"
    echo "  Swap:   $swap_limit"
    echo ""

    # Check if image exists, build if not
    if ! image_exists "$IMAGE_NAME:$IMAGE_TAG"; then
        log_info "Building container image (this may take a few minutes)..."
        build_image
    fi

    # Remove existing container if any
    if container_exists "$CONTAINER_NAME"; then
        log_warn "Container '$CONTAINER_NAME' already exists"
        if confirm "Remove and recreate?"; then
            remove_container "$CONTAINER_NAME"
        else
            if container_running "$CONTAINER_NAME"; then
                log_info "Entering existing container..."
                enter_container "$CONTAINER_NAME"
                return
            else
                start_container "$CONTAINER_NAME"
                enter_container "$CONTAINER_NAME"
                return
            fi
        fi
    fi

    # Start container
    log_info "Starting container..."

    # Try docker compose first, fallback to docker run
    local compose_works=false
    if docker compose version &>/dev/null; then
        CLOUD_CPUS="$cpu_limit" CLOUD_MEM_LIMIT="$mem_limit" CLOUD_MEMSWAP_LIMIT="$swap_limit" \
            docker compose -f "$COMPOSE_FILE" up -d && compose_works=true
    fi

    if ! $compose_works; then
        log_info "Using docker run (compose unavailable)..."
        docker run -d \
            --name "$CONTAINER_NAME" \
            --hostname cloud-connect \
            --cpus="$cpu_limit" \
            --memory="$mem_limit" \
            --memory-swap="$swap_limit" \
            --oom-score-adj=500 \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_ADMIN \
            --security-opt apparmor:unconfined \
            --network host \
            --dns 1.1.1.1 \
            --dns 1.0.0.1 \
            -v "$SCRIPT_DIR/lib:/opt/cloud-connect/lib:ro" \
            -v "$SCRIPT_DIR/modules:/opt/cloud-connect/modules:ro" \
            -v "$SCRIPT_DIR/configs:/opt/cloud-connect/configs:ro" \
            -v "/tmp/.X11-unix:/tmp/.X11-unix:rw" \
            -e "DISPLAY=${DISPLAY:-:0}" \
            -e "CLOUD_IN_CONTAINER=1" \
            -e "CLOUD_ROOT=/opt/cloud-connect" \
            -e "TZ=${TZ:-UTC}" \
            -it \
            "$IMAGE_NAME:$IMAGE_TAG"
    fi

    # Wait for container to be ready
    log_info "Waiting for container to be ready..."
    if wait_for "container_running $CONTAINER_NAME" 30; then
        log_success "Container ready!"
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  ${GREEN}Anonymous environment ready!${NC}"
        echo ""
        echo "  Features:"
        echo "    ${GREEN}✓${NC} ProtonVPN (free tier)"
        echo "    ${GREEN}✓${NC} Encrypted DNS"
        echo "    ${GREEN}✓${NC} Brave browser"
        echo ""
        echo "  Next steps:"
        echo "    ${CYAN}cloud tools install${NC}  - Add dev tools"
        echo "    ${CYAN}cloud vault load${NC}     - Load personal vault"
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
    else
        die "Container failed to start"
    fi

    # Enter container
    enter_container "$CONTAINER_NAME"
}

show_status() {
    require_docker

    log_header "Cloud Connect Status"

    if container_running "$CONTAINER_NAME"; then
        status_ok "Container: Running"
        echo ""
        container_stats "$CONTAINER_NAME"
    elif container_exists "$CONTAINER_NAME"; then
        status_fail "Container: Stopped"
        echo "  Start with: ./cloud-connect.sh start"
    else
        status_skip "Container: Not created"
        echo "  Create with: ./cloud-connect.sh"
    fi
}

show_logs() {
    require_docker

    if container_exists "$CONTAINER_NAME"; then
        container_logs "$CONTAINER_NAME" "${1:-100}"
    else
        die "Container does not exist"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MODULE RUNNER
# ═══════════════════════════════════════════════════════════════════════════

run_module() {
    local module=$1
    shift

    if ! container_running "$CONTAINER_NAME"; then
        die "Container is not running. Start it first with: ./cloud-connect.sh"
    fi

    local module_path="/opt/cloud-connect/modules/$module"
    local main_script

    # Determine main script based on module
    case "$module" in
        00-base)    main_script="$module_path/entrypoint.sh" ;;
        01-tools)   main_script="$module_path/install.sh" ;;
        02-desktop) main_script="$module_path/desktop.sh" ;;
        03-vault)   main_script="$module_path/vault.sh" ;;
        04-vpn)     main_script="$module_path/wireguard.sh" ;;
        05-ssh)     main_script="$module_path/ssh.sh" ;;
        06-mount)   main_script="$module_path/mount.sh" ;;
        07-config)  main_script="$module_path/config.sh" ;;
        08-status)  main_script="$module_path/status.sh" ;;
        09-export)  main_script="$module_path/export.sh" ;;
        *)          die "Unknown module: $module" ;;
    esac

    docker exec -it "$CONTAINER_NAME" "$main_script" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    # Handle global options
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        --debug)
            export CLOUD_DEBUG=1
            shift
            ;;
    esac

    # Route to command
    case "${1:-start}" in
        # Container commands
        ""|start|up)
            create_container
            ;;
        enter|shell)
            require_docker
            if container_running "$CONTAINER_NAME"; then
                enter_container "$CONTAINER_NAME"
            else
                die "Container is not running. Start it first."
            fi
            ;;
        stop|down)
            require_docker
            stop_container "$CONTAINER_NAME"
            log_success "Container stopped"
            ;;
        destroy|rm|remove)
            require_docker
            if confirm "This will remove the container and all data. Continue?"; then
                remove_container "$CONTAINER_NAME"
                log_success "Container removed"
            fi
            ;;
        restart)
            require_docker
            stop_container "$CONTAINER_NAME"
            start_container "$CONTAINER_NAME"
            ;;
        logs)
            show_logs "${2:-100}"
            ;;

        # Module commands
        tools)
            run_module "01-tools" "${@:2}"
            ;;
        desktop)
            run_module "02-desktop" "${@:2}"
            ;;
        vault)
            run_module "03-vault" "${@:2}"
            ;;
        vpn)
            run_module "04-vpn" "${@:2}"
            ;;
        ssh)
            run_module "05-ssh" "${@:2}"
            ;;
        mount)
            run_module "06-mount" "${@:2}"
            ;;
        config)
            run_module "07-config" "${@:2}"
            ;;
        status)
            if [[ -z "${2:-}" ]]; then
                show_status
            else
                run_module "08-status" "${@:2}"
            fi
            ;;
        export)
            run_module "09-export" "${@:2}"
            ;;

        # Unknown
        *)
            log_error "Unknown command: $1"
            echo "Run './cloud-connect.sh --help' for usage"
            exit 1
            ;;
    esac
}

# Run main
main "$@"
