#!/bin/bash
# Deploy Sauron-Lite to VMs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="/home/diego/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa"

# VM definitions
declare -A VMS=(
    ["oci-micro-1"]="ubuntu@130.110.251.193"
    ["oci-micro-2"]="ubuntu@129.151.228.66"
    ["gcp-arch-1"]="gcloud:arch-1"
)

deploy_vm() {
    local vm_name="$1"
    local target="${VMS[$vm_name]}"

    echo "=== Deploying to $vm_name ==="

    if [[ "$target" == gcloud:* ]]; then
        local instance="${target#gcloud:}"
        # GCP deployment
        gcloud compute scp --zone=us-central1-a --recurse \
            "$SCRIPT_DIR"/{Dockerfile,docker-compose.yml,watcher.sh} \
            "$instance":~/sauron-lite/
        gcloud compute ssh "$instance" --zone=us-central1-a --command="
            cd ~/sauron-lite &&
            export VM_NAME='$vm_name' &&
            docker compose down 2>/dev/null || true &&
            docker compose build --no-cache &&
            docker compose up -d
        "
    else
        # OCI/SSH deployment
        ssh -i "$SSH_KEY" "$target" "mkdir -p ~/sauron-lite"
        scp -i "$SSH_KEY" \
            "$SCRIPT_DIR"/{Dockerfile,docker-compose.yml,watcher.sh} \
            "$target":~/sauron-lite/
        ssh -i "$SSH_KEY" "$target" "
            cd ~/sauron-lite &&
            export VM_NAME='$vm_name' &&
            docker compose down 2>/dev/null || true &&
            docker compose build --no-cache &&
            docker compose up -d
        "
    fi

    echo "=== $vm_name deployed ==="
}

status_all() {
    for vm_name in "${!VMS[@]}"; do
        local target="${VMS[$vm_name]}"
        echo "=== $vm_name ==="

        if [[ "$target" == gcloud:* ]]; then
            local instance="${target#gcloud:}"
            gcloud compute ssh "$instance" --zone=us-central1-a --command="
                docker ps --filter 'name=sauron' --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'
                echo 'Memory:'
                docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' sauron sauron-forwarder 2>/dev/null || true
            " 2>/dev/null || echo "Unreachable"
        else
            ssh -i "$SSH_KEY" -o ConnectTimeout=5 "$target" "
                docker ps --filter 'name=sauron' --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'
                echo 'Memory:'
                docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' sauron sauron-forwarder 2>/dev/null || true
            " 2>/dev/null || echo "Unreachable"
        fi
    done
}

case "${1:-help}" in
    deploy)
        if [[ -n "${2:-}" ]]; then
            deploy_vm "$2"
        else
            for vm in "${!VMS[@]}"; do
                deploy_vm "$vm"
            done
        fi
        ;;
    status)
        status_all
        ;;
    *)
        echo "Usage: $0 {deploy [vm]|status}"
        echo "VMs: ${!VMS[*]}"
        ;;
esac
