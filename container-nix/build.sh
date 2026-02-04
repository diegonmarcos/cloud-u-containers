#!/bin/sh
# Cloud Infrastructure - Nix Flake Build & Deploy Script
# Builds Docker Compose configs and deploys to VMs via SSH
# Configuration loaded from config.json
set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Check dependencies
check_deps() {
    for cmd in jq nix rsync ssh; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
}

# Load config values
load_config() {
    SSH_KEY=$(jq -r '.ssh_key' "$CONFIG_FILE")
    REMOTE_BASE=$(jq -r '.remote_base' "$CONFIG_FILE")
}

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
    build [service]     Build Nix flakes locally (all or specific service)
    deploy [service]    Build and deploy to VMs (all or specific service)
    list                List all services and their target VMs
    vms                 List all VMs
    ssh <vm>            SSH into a VM
    restart <service>   Restart a service on its VM
    status <vm>         Show docker status on a VM

Options:
    -n, --dry-run       Show what would be done without executing
    -v, --verbose       Verbose output
    -h, --help          Show this help

Examples:
    $0 build                    # Build all services
    $0 build authelia           # Build only authelia
    $0 deploy                   # Build and deploy all
    $0 deploy mailu             # Deploy only mailu
    $0 ssh oci-f-micro_1        # SSH into Oracle Micro 1
    $0 restart photoprism       # Restart photoprism on its VM
EOF
    exit 0
}

log() {
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"
}

log_error() {
    printf "[%s] ERROR: %s\n" "$(date '+%H:%M:%S')" "$1" >&2
}

# Get VM property from config
get_vm_prop() {
    vm_name="$1"
    prop="$2"
    jq -r ".vms[\"$vm_name\"].$prop // empty" "$CONFIG_FILE"
}

# Get service property from config
get_svc_prop() {
    svc_name="$1"
    prop="$2"
    jq -r ".services[\"$svc_name\"].$prop // empty" "$CONFIG_FILE"
}

# Get all VM names
get_all_vms() {
    jq -r '.vms | keys[]' "$CONFIG_FILE"
}

# Get all service names
get_all_services() {
    jq -r '.services | keys[]' "$CONFIG_FILE"
}

# Get folder name for a service
get_service_folder() {
    service="$1"
    category=$(get_svc_prop "$service" "category")
    flake=$(get_svc_prop "$service" "flake")

    # Use flake name if specified, otherwise service name
    base_name="${flake:-$service}"

    # Map category to folder prefix
    case "$category" in
        app)    echo "app_${base_name}" ;;
        tools)  echo "bac_tools-${base_name}" ;;
        sec)    echo "bac_sec-${base_name}" ;;
        cloud)  echo "bac_cloud-${base_name}" ;;
        *)      echo "$base_name" ;;
    esac
}

# SSH into a VM
ssh_cmd() {
    vm_name="$1"
    shift
    cmd="$*"

    method=$(get_vm_prop "$vm_name" "method")
    if [ -z "$method" ]; then
        log_error "Unknown VM: $vm_name"
        return 1
    fi

    ip=$(get_vm_prop "$vm_name" "ip")
    user=$(get_vm_prop "$vm_name" "user")

    if [ "$method" = "gcloud" ]; then
        instance=$(get_vm_prop "$vm_name" "gcloud_instance")
        zone=$(get_vm_prop "$vm_name" "gcloud_zone")
        if [ -n "$cmd" ]; then
            gcloud compute ssh "$user@$instance" --zone "$zone" --command "$cmd"
        else
            gcloud compute ssh "$user@$instance" --zone "$zone"
        fi
    else
        if [ -n "$cmd" ]; then
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd"
        else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$user@$ip"
        fi
    fi
}

# Rsync files to a VM
rsync_to_vm() {
    vm_name="$1"
    src="$2"
    dest="$3"

    method=$(get_vm_prop "$vm_name" "method")
    ip=$(get_vm_prop "$vm_name" "ip")
    user=$(get_vm_prop "$vm_name" "user")

    if [ "$method" = "gcloud" ]; then
        instance=$(get_vm_prop "$vm_name" "gcloud_instance")
        zone=$(get_vm_prop "$vm_name" "gcloud_zone")
        gcloud compute scp --recurse "$src" "$user@$instance:$dest" --zone "$zone"
    else
        rsync -avz --delete -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
            "$src" "$user@$ip:$dest"
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_build() {
    service="$1"

    cd "$SCRIPT_DIR"

    if [ -n "$service" ]; then
        # Get the flake name (may differ from service name for syslog-*)
        flake=$(get_svc_prop "$service" "flake")
        flake_name="${flake:-$service}"

        log "Building $flake_name..."
        nix build ".#$flake_name" --out-link "result-$flake_name"
        log "Built: result-$flake_name"
    else
        log "Building all services..."
        nix build ".#all" --out-link "result"
        log "Built: result/"
        log "  result/sec/  - Security services"
        log "  result/app/  - Application services"
        log "  result/bac/  - Backend services"
    fi
}

cmd_deploy() {
    service="$1"

    cd "$SCRIPT_DIR"

    if [ -n "$service" ]; then
        deploy_service "$service"
    else
        log "Deploying all services..."
        get_all_services | while read -r svc; do
            deploy_service "$svc"
        done
    fi
}

deploy_service() {
    service="$1"

    vm=$(get_svc_prop "$service" "vm")
    if [ -z "$vm" ]; then
        log_error "No VM configured for service: $service"
        return 1
    fi

    subfolder=$(get_svc_prop "$service" "subfolder")
    flake=$(get_svc_prop "$service" "flake")
    flake_name="${flake:-$service}"

    log "Building $flake_name..."
    nix build ".#$flake_name" --out-link "result-$flake_name"

    # Determine source and destination paths
    if [ -n "$subfolder" ]; then
        src_path="$SCRIPT_DIR/result-$flake_name/$subfolder/"
        remote_name="$service"
    else
        src_path="$SCRIPT_DIR/result-$flake_name/"
        remote_name="$service"
    fi

    log "Deploying $service to $vm..."

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] Would sync $src_path to $vm:$REMOTE_BASE/$remote_name/"
    else
        # Create remote directory
        ssh_cmd "$vm" "sudo mkdir -p $REMOTE_BASE/$remote_name && sudo chown \$(whoami):\$(whoami) $REMOTE_BASE/$remote_name"

        # Sync files
        rsync_to_vm "$vm" "$src_path" "$REMOTE_BASE/$remote_name/"
        log "Deployed $service to $vm:$REMOTE_BASE/$remote_name/"
    fi
}

cmd_list() {
    printf "\n%-25s %-8s %-15s %-20s %s\n" "SERVICE" "TYPE" "VM" "IP" "DESCRIPTION"
    printf "%s\n" "-------------------------------------------------------------------------------------"

    get_all_services | while read -r svc; do
        category=$(get_svc_prop "$svc" "category")
        vm=$(get_svc_prop "$svc" "vm")
        desc=$(get_svc_prop "$svc" "description")
        ip=$(get_vm_prop "$vm" "ip")
        printf "%-25s %-8s %-15s %-20s %s\n" "$svc" "$category" "$vm" "$ip" "$desc"
    done | sort

    printf "\n"
}

cmd_vms() {
    printf "\n%-15s %-20s %-10s %-10s %s\n" "VM" "IP" "USER" "METHOD" "DESCRIPTION"
    printf "%s\n" "--------------------------------------------------------------------------------"

    get_all_vms | while read -r vm; do
        ip=$(get_vm_prop "$vm" "ip")
        user=$(get_vm_prop "$vm" "user")
        method=$(get_vm_prop "$vm" "method")
        desc=$(get_vm_prop "$vm" "description")
        printf "%-15s %-20s %-10s %-10s %s\n" "$vm" "$ip" "$user" "$method" "$desc"
    done

    printf "\n"
}

cmd_ssh() {
    vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required. Available VMs:"
        get_all_vms | while read -r vm; do
            printf "  - %s\n" "$vm"
        done
        exit 1
    fi

    log "Connecting to $vm_name..."
    ssh_cmd "$vm_name"
}

cmd_restart() {
    service="$1"
    if [ -z "$service" ]; then
        log_error "Service name required"
        usage
    fi

    vm=$(get_svc_prop "$service" "vm")
    if [ -z "$vm" ]; then
        log_error "Unknown service: $service"
        return 1
    fi

    log "Restarting $service on $vm..."
    ssh_cmd "$vm" "cd $REMOTE_BASE/$service && docker-compose down && docker-compose up -d"
    log "Restarted $service"
}

cmd_status() {
    vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi

    log "Docker status on $vm_name:"
    ssh_cmd "$vm_name" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
}

# =============================================================================
# Main
# =============================================================================

DRY_RUN=0
VERBOSE=0

# Parse global options
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            set -x
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            break
            ;;
    esac
done

command="${1:-}"
shift 2>/dev/null || true

# Initialize
check_deps
load_config

case "$command" in
    build)
        cmd_build "$@"
        ;;
    deploy)
        cmd_deploy "$@"
        ;;
    list)
        cmd_list
        ;;
    vms)
        cmd_vms
        ;;
    ssh)
        cmd_ssh "$@"
        ;;
    restart)
        cmd_restart "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    ""|help)
        usage
        ;;
    *)
        log_error "Unknown command: $command"
        usage
        ;;
esac
