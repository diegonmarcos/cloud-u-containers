#!/bin/bash
# NocoDB Deployment Script
# Target: oci-p-flex_1 (144.24.196.72)

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SSH_KEY="${SSH_KEY:-$HOME/Mounts/Git/vault/A0_keys/ssh/id_rsa}"
REMOTE_USER="ubuntu"
REMOTE_HOST="144.24.196.72"
REMOTE_DIR="/home/ubuntu/nocodb"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# SSH helper
ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

scp_cmd() {
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$@"
}

# Commands
cmd_check() {
    log "Checking VM connectivity..."
    if ssh_cmd "echo 'VM is reachable'" 2>/dev/null; then
        log "VM is online"
        ssh_cmd "docker --version && docker compose version"
    else
        error "Cannot connect to VM. Is it running?"
    fi
}

cmd_upload() {
    log "Uploading files to $REMOTE_HOST:$REMOTE_DIR..."

    ssh_cmd "mkdir -p $REMOTE_DIR"

    scp_cmd "$PROJECT_DIR/docker-compose.yml" "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_DIR/"

    if [[ -f "$PROJECT_DIR/.env" ]]; then
        scp_cmd "$PROJECT_DIR/.env" "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_DIR/"
        log "Uploaded .env file"
    else
        warn ".env file not found locally. Will generate on server."
    fi

    log "Files uploaded successfully"
}

cmd_init_env() {
    log "Generating .env file on server..."

    ssh_cmd "cd $REMOTE_DIR && cat > .env << 'ENVEOF'
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
NC_AUTH_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/+=')
NC_ADMIN_EMAIL=diego@diegonmarcos.com
NC_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')
ENVEOF"

    log "Environment file created. Fetching credentials..."
    echo ""
    echo "========== SAVE THESE CREDENTIALS TO BITWARDEN =========="
    ssh_cmd "cat $REMOTE_DIR/.env"
    echo "========================================================="
    echo ""
}

cmd_deploy() {
    log "Deploying NocoDB..."

    ssh_cmd "cd $REMOTE_DIR && sudo docker compose pull"
    ssh_cmd "cd $REMOTE_DIR && sudo docker compose up -d"

    log "Waiting for containers to start..."
    sleep 10

    ssh_cmd "sudo docker ps | grep -E 'nocodb|CONTAINER'"

    log "Deployment complete!"
}

cmd_status() {
    log "Checking NocoDB status..."
    ssh_cmd "sudo docker ps | grep -E 'nocodb|CONTAINER'"
    echo ""
    ssh_cmd "sudo docker logs nocodb --tail 20 2>&1 | tail -10"
}

cmd_logs() {
    local container="${1:-nocodb}"
    ssh_cmd "sudo docker logs $container --tail 100 -f"
}

cmd_stop() {
    log "Stopping NocoDB..."
    ssh_cmd "cd $REMOTE_DIR && sudo docker compose down"
}

cmd_restart() {
    log "Restarting NocoDB..."
    ssh_cmd "cd $REMOTE_DIR && sudo docker compose restart"
}

cmd_backup() {
    log "Creating database backup..."
    local backup_name="nocodb_backup_$(date +%Y%m%d_%H%M%S).sql"
    ssh_cmd "sudo docker exec nocodb-db pg_dump -U nocodb nocodb > /tmp/$backup_name"
    scp_cmd "${REMOTE_USER}@${REMOTE_HOST}:/tmp/$backup_name" "$PROJECT_DIR/backups/"
    log "Backup saved to $PROJECT_DIR/backups/$backup_name"
}

cmd_destroy() {
    warn "This will delete all NocoDB data!"
    read -p "Are you sure? (type 'yes'): " confirm
    if [[ "$confirm" == "yes" ]]; then
        ssh_cmd "cd $REMOTE_DIR && sudo docker compose down -v"
        ssh_cmd "rm -rf $REMOTE_DIR"
        log "NocoDB destroyed"
    else
        log "Aborted"
    fi
}

cmd_full_deploy() {
    cmd_check
    cmd_upload
    cmd_init_env
    cmd_deploy
    cmd_status

    echo ""
    log "NocoDB deployed! Next steps:"
    echo "  1. Save credentials to Bitwarden"
    echo "  2. Configure NPM proxy host for db.diegonmarcos.com"
    echo "  3. Add Cloudflare DNS record"
    echo "  4. Update Authelia access rules"
}

cmd_help() {
    cat << EOF
NocoDB Deployment Script

Usage: $0 <command>

Commands:
  check       Check VM connectivity
  upload      Upload files to server
  init-env    Generate .env file on server
  deploy      Deploy containers
  full        Full deployment (check + upload + init-env + deploy)
  status      Show container status
  logs [c]    Follow container logs (default: nocodb)
  stop        Stop containers
  restart     Restart containers
  backup      Backup PostgreSQL database
  destroy     Remove all NocoDB data (dangerous!)
  help        Show this help

Examples:
  $0 full           # Full deployment
  $0 status         # Check status
  $0 logs nocodb-db # View database logs
EOF
}

# Main
case "${1:-help}" in
    check)      cmd_check ;;
    upload)     cmd_upload ;;
    init-env)   cmd_init_env ;;
    deploy)     cmd_deploy ;;
    full)       cmd_full_deploy ;;
    status)     cmd_status ;;
    logs)       cmd_logs "$2" ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart ;;
    backup)     cmd_backup ;;
    destroy)    cmd_destroy ;;
    help|*)     cmd_help ;;
esac
