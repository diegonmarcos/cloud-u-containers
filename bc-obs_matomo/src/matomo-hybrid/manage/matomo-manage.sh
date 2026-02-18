#!/bin/sh
# Matomo Hybrid Management Script (POSIX-compliant)
# Manage the matomo-hybrid container and its internal services

set -e

SERVER_IP="129.151.228.66"
SSH_KEY="${HOME}/.ssh/matomo_key"
SSH_USER="ubuntu"
CONTAINER="matomo-hybrid"

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH key not found at ${SSH_KEY}"
    exit 1
fi

show_usage() {
    cat << EOF
Matomo Hybrid Management Script
=================================

Usage: $0 [COMMAND]

Container Commands:
  start       Start matomo-hybrid container (receiver only)
  stop        Stop matomo-hybrid container entirely
  restart     Restart matomo-hybrid container
  status      Show container and service status
  logs        Show container logs

Matomo Commands:
  wake        Start MariaDB + Matomo (full stack) + import inbox
  sleep       Stop MariaDB + Matomo (keep receiver running)
  import      Import buffered inbox payloads into Matomo
  inbox       Show inbox payload count

Maintenance:
  backup      Backup Matomo data and database
  update      Rebuild and restart container
  shell       Open shell in container
  archive     Run Matomo archiving manually

Examples:
  $0 start                # Start container (receiver only ~30-50MB)
  $0 wake                 # Wake Matomo (full stack ~500-700MB)
  $0 sleep                # Sleep Matomo (back to ~30-50MB)
  $0 inbox                # Check how many payloads are buffered
  $0 import               # Manually import buffered payloads
EOF
}

run_remote() {
    ssh -i "${SSH_KEY}" "${SSH_USER}@${SERVER_IP}" "$@"
}

case "${1:-}" in
    start)
        echo "Starting matomo-hybrid container..."
        run_remote "cd ~/matomo-hybrid && docker compose up -d"
        echo "Container started (receiver mode, ~30-50MB RAM)"
        ;;
    stop)
        echo "Stopping matomo-hybrid container..."
        run_remote "cd ~/matomo-hybrid && docker compose down"
        echo "Container stopped"
        ;;
    restart)
        echo "Restarting matomo-hybrid container..."
        run_remote "cd ~/matomo-hybrid && docker compose restart"
        echo "Container restarted"
        ;;
    status)
        echo "Matomo Hybrid Status:"
        echo ""
        run_remote "docker ps --filter name=${CONTAINER} --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
        echo ""
        echo "Internal services:"
        run_remote "docker exec ${CONTAINER} supervisorctl status"
        echo ""
        echo "Memory usage:"
        run_remote "docker stats ${CONTAINER} --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'"
        ;;
    logs)
        echo "Matomo logs (Ctrl+C to exit):"
        echo ""
        run_remote "docker logs ${CONTAINER} -f --tail=50"
        ;;
    wake)
        echo "Waking Matomo (starting full stack)..."
        run_remote "docker exec ${CONTAINER} /scripts/matomo-wake.sh"
        ;;
    sleep)
        echo "Putting Matomo to sleep..."
        run_remote "docker exec ${CONTAINER} /scripts/matomo-sleep.sh"
        ;;
    import)
        echo "Importing buffered payloads..."
        run_remote "docker exec ${CONTAINER} /scripts/import-inbox.sh"
        ;;
    inbox)
        echo "Inbox status:"
        run_remote "docker exec ${CONTAINER} sh -c 'echo \"Payloads buffered: \$(find /inbox -name \"*.json\" 2>/dev/null | wc -l)\"'"
        ;;
    backup)
        BACKUP_NAME="matomo-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        echo "Creating backup: ${BACKUP_NAME}"
        # First wake to ensure DB is running for a proper dump
        echo "Waking Matomo for database backup..."
        run_remote "docker exec ${CONTAINER} /scripts/matomo-wake.sh"
        # Database dump
        run_remote "docker exec ${CONTAINER} mariadb-dump -u root matomo | gzip > ~/matomo-db-${BACKUP_NAME}"
        # Backup compose directory
        run_remote "cd ~ && tar -czf ${BACKUP_NAME} matomo-hybrid/"
        echo "Backup created on server:"
        echo "  Database: ~/matomo-db-${BACKUP_NAME}"
        echo "  Files:    ~/${BACKUP_NAME}"
        echo ""
        echo "Download with:"
        echo "  scp -i ${SSH_KEY} ${SSH_USER}@${SERVER_IP}:~/${BACKUP_NAME} ."
        ;;
    update)
        echo "Rebuilding matomo-hybrid image..."
        run_remote "cd ~/matomo-hybrid && docker compose build && docker compose up -d"
        echo "Container updated and restarted"
        ;;
    shell)
        echo "Opening shell in matomo-hybrid..."
        run_remote "docker exec -it ${CONTAINER} /bin/bash"
        ;;
    archive)
        echo "Running Matomo archiving..."
        run_remote "docker exec ${CONTAINER} php /var/www/html/console core:archive --force-all-websites"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
