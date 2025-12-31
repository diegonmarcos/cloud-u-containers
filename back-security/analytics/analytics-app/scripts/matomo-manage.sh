#!/bin/sh
# Matomo Management Script (POSIX-compliant)
# Manage Matomo Docker containers

set -e

SERVER_IP="130.110.251.193"
SSH_KEY="${HOME}/.ssh/matomo_key"
SSH_USER="ubuntu"

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH key not found at ${SSH_KEY}"
    exit 1
fi

show_usage() {
    cat << EOF
Matomo Management Script
========================

Usage: $0 [COMMAND]

Commands:
  start       Start Matomo containers
  stop        Stop Matomo containers
  restart     Restart Matomo containers
  status      Show container status
  logs        Show container logs
  backup      Backup Matomo data
  update      Update Matomo images
  shell       Open shell in Matomo container

Examples:
  $0 start
  $0 logs
  $0 status
EOF
}

run_remote() {
    ssh -i "${SSH_KEY}" "${SSH_USER}@${SERVER_IP}" "$@"
}

case "${1:-}" in
    start)
        echo "Starting Matomo containers..."
        run_remote "cd ~/matomo && docker-compose up -d"
        echo "✅ Matomo started"
        ;;
    stop)
        echo "Stopping Matomo containers..."
        run_remote "cd ~/matomo && docker-compose down"
        echo "✅ Matomo stopped"
        ;;
    restart)
        echo "Restarting Matomo containers..."
        run_remote "cd ~/matomo && docker-compose restart"
        echo "✅ Matomo restarted"
        ;;
    status)
        echo "Matomo container status:"
        echo ""
        run_remote "cd ~/matomo && docker-compose ps"
        ;;
    logs)
        echo "Matomo logs (Ctrl+C to exit):"
        echo ""
        run_remote "cd ~/matomo && docker-compose logs -f --tail=50"
        ;;
    backup)
        BACKUP_NAME="matomo-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        echo "Creating backup: ${BACKUP_NAME}"
        run_remote "cd ~ && tar -czf ${BACKUP_NAME} matomo/"
        echo "✅ Backup created on server: ~/${BACKUP_NAME}"
        echo ""
        echo "Download with:"
        echo "  scp -i ${SSH_KEY} ${SSH_USER}@${SERVER_IP}:~/${BACKUP_NAME} ."
        ;;
    update)
        echo "Updating Matomo images..."
        run_remote "cd ~/matomo && docker-compose pull && docker-compose up -d"
        echo "✅ Matomo updated"
        ;;
    shell)
        echo "Opening shell in Matomo container..."
        run_remote "docker exec -it matomo-app /bin/bash"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
