#!/usr/bin/env bash
#
# Cloud Connect - Container Command Router
#
# This is the "cloud" command available inside the container
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
MODULES_DIR="$CLOUD_ROOT/modules"

# Source libraries
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

show_help() {
    cat << EOF
${BOLD}Cloud Connect${NC} - Container Commands

${BOLD}USAGE:${NC}
    cloud <command> [options]

${BOLD}COMMANDS:${NC}
    tools           Manage development tools
    desktop         Manage KDE desktop
    vault           Manage personal vault
    vpn             Manage VPN connection
    ssh             SSH connections
    mount           FUSE mounts
    config          Apply configurations
    status          Show status
    export          Export data

${BOLD}EXAMPLES:${NC}
    cloud tools install python node rust
    cloud vault load /path/to/vault
    cloud vpn up
    cloud mount up
    cloud status

EOF
}

run_module() {
    local module_num=$1
    local module_name=$2
    shift 2

    local module_dir="$MODULES_DIR/$module_num-$module_name"
    local main_script

    case "$module_name" in
        tools)   main_script="$module_dir/install.sh" ;;
        desktop) main_script="$module_dir/desktop.sh" ;;
        vault)   main_script="$module_dir/vault.sh" ;;
        vpn)     main_script="$module_dir/wireguard.sh" ;;
        ssh)     main_script="$module_dir/ssh.sh" ;;
        mount)   main_script="$module_dir/mount.sh" ;;
        config)  main_script="$module_dir/config.sh" ;;
        status)  main_script="$module_dir/status.sh" ;;
        export)  main_script="$module_dir/export.sh" ;;
        *)
            die "Unknown module: $module_name"
            ;;
    esac

    if [[ -x "$main_script" ]]; then
        "$main_script" "$@"
    else
        log_error "Module not installed: $module_name"
        log_info "Available at: $main_script"
        exit 1
    fi
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            exit 0
            ;;
        tools)
            run_module "01" "tools" "${@:2}"
            ;;
        desktop)
            run_module "02" "desktop" "${@:2}"
            ;;
        vault)
            run_module "03" "vault" "${@:2}"
            ;;
        vpn)
            run_module "04" "vpn" "${@:2}"
            ;;
        ssh)
            run_module "05" "ssh" "${@:2}"
            ;;
        mount)
            run_module "06" "mount" "${@:2}"
            ;;
        config)
            run_module "07" "config" "${@:2}"
            ;;
        status)
            run_module "08" "status" "${@:2}"
            ;;
        export)
            run_module "09" "export" "${@:2}"
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run 'cloud --help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
