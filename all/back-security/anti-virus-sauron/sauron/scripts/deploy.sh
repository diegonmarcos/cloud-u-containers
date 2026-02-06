#!/bin/bash
set -euo pipefail

# Sauron Deployment Script
# Deploys to all VMs via SSH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="/opt/sauron"

# VM Configuration
declare -A VMS=(
    ["oci-web1"]="ubuntu@130.110.251.193"
    ["oci-svc1"]="ubuntu@129.151.228.66"
    ["gcp-arch1"]="diego@34.55.55.234"
)

SSH_KEY="/home/diego/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa"
GCP_SSH="gcloud compute ssh arch-1 --zone=us-central1-a"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 <command> [vm_name]

Commands:
    deploy [vm]     Deploy to VM (or all if no vm specified)
    status [vm]     Check status on VM(s)
    logs [vm]       View logs from VM
    stop [vm]       Stop Sauron on VM(s)
    restart [vm]    Restart Sauron on VM(s)
    update-rules    Update YARA rules on all VMs

VMs: ${!VMS[*]}
EOF
    exit 1
}

ssh_cmd() {
    local vm=$1
    local cmd=$2

    if [[ "$vm" == "gcp-arch1" ]]; then
        $GCP_SSH --command="$cmd"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${VMS[$vm]}" "$cmd"
    fi
}

scp_cmd() {
    local vm=$1
    local src=$2
    local dst=$3

    if [[ "$vm" == "gcp-arch1" ]]; then
        gcloud compute scp --zone=us-central1-a "$src" "arch-1:$dst"
    else
        scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r "$src" "${VMS[$vm]}:$dst"
    fi
}

deploy_vm() {
    local vm=$1
    log "Deploying to $vm..."

    # Create remote directory
    ssh_cmd "$vm" "sudo mkdir -p $REMOTE_DIR && sudo chown \$(whoami) $REMOTE_DIR"

    # Copy files
    log "Copying files to $vm..."
    scp_cmd "$vm" "$SCRIPT_DIR/docker-compose.yml" "$REMOTE_DIR/"
    scp_cmd "$vm" "$SCRIPT_DIR/Dockerfile.sauron" "$REMOTE_DIR/"
    scp_cmd "$vm" "$SCRIPT_DIR/config" "$REMOTE_DIR/"
    scp_cmd "$vm" "$SCRIPT_DIR/yara-rules" "$REMOTE_DIR/"

    # Create .env file
    log "Creating environment file..."
    ssh_cmd "$vm" "cat > $REMOTE_DIR/.env << EOF
VM_NAME=$vm
CENTRAL_HOST=34.55.55.234
CENTRAL_PORT=5514
EOF"

    # Build and start
    log "Starting containers on $vm..."
    ssh_cmd "$vm" "cd $REMOTE_DIR && docker compose build && docker compose up -d"

    log "Deployed to $vm successfully!"
}

status_vm() {
    local vm=$1
    log "Status for $vm:"
    ssh_cmd "$vm" "cd $REMOTE_DIR 2>/dev/null && docker compose ps || echo 'Not deployed'"
}

logs_vm() {
    local vm=$1
    log "Logs from $vm:"
    ssh_cmd "$vm" "cd $REMOTE_DIR && docker compose logs --tail=50"
}

stop_vm() {
    local vm=$1
    log "Stopping Sauron on $vm..."
    ssh_cmd "$vm" "cd $REMOTE_DIR && docker compose down"
}

restart_vm() {
    local vm=$1
    log "Restarting Sauron on $vm..."
    ssh_cmd "$vm" "cd $REMOTE_DIR && docker compose restart"
}

update_rules() {
    for vm in "${!VMS[@]}"; do
        log "Updating YARA rules on $vm..."
        scp_cmd "$vm" "$SCRIPT_DIR/yara-rules" "$REMOTE_DIR/"
        ssh_cmd "$vm" "cd $REMOTE_DIR && docker compose restart sauron"
    done
    log "Rules updated on all VMs!"
}

run_on_vms() {
    local func=$1
    local target=${2:-}

    if [[ -n "$target" ]]; then
        if [[ -z "${VMS[$target]:-}" ]]; then
            error "Unknown VM: $target"
            exit 1
        fi
        $func "$target"
    else
        for vm in "${!VMS[@]}"; do
            $func "$vm"
            echo ""
        done
    fi
}

# Main
[[ $# -lt 1 ]] && usage

case "$1" in
    deploy)      run_on_vms deploy_vm "${2:-}" ;;
    status)      run_on_vms status_vm "${2:-}" ;;
    logs)        run_on_vms logs_vm "${2:-}" ;;
    stop)        run_on_vms stop_vm "${2:-}" ;;
    restart)     run_on_vms restart_vm "${2:-}" ;;
    update-rules) update_rules ;;
    *)           usage ;;
esac
