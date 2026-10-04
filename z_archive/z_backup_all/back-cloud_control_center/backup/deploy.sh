#!/bin/bash
# Deploy backup infrastructure to Flex VM
# Usage: ./deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_KEY="/home/diego/Mounts/Git/vault/A0_keys/ssh/id_rsa"
FLEX_HOST="ubuntu@144.24.196.72"

log() { echo "=== $1 ==="; }

# ═══════════════════════════════════════════════════════════════
# SETUP FLEX VM
# ═══════════════════════════════════════════════════════════════

log "Setting up Flex VM backup infrastructure"

ssh -i "$SSH_KEY" "$FLEX_HOST" << 'REMOTE'
set -e

# Create backup directories
sudo mkdir -p /backup/{code/gitea-data,databases,media}
sudo chown -R ubuntu:ubuntu /backup

# Install dependencies
sudo apt-get update
sudo apt-get install -y borgbackup bup docker-compose-plugin

# Initialize bup repo
export BUP_DIR=/backup/databases
bup init 2>/dev/null || true

echo "Flex VM ready!"
REMOTE

# ═══════════════════════════════════════════════════════════════
# DEPLOY GITEA (Code mirrors)
# ═══════════════════════════════════════════════════════════════

log "Deploying Gitea"

scp -i "$SSH_KEY" \
    "$SCRIPT_DIR/gitea/docker-compose.yml" \
    "$SCRIPT_DIR/gitea/setup.sh" \
    "$FLEX_HOST:/tmp/"

ssh -i "$SSH_KEY" "$FLEX_HOST" << 'REMOTE'
sudo mkdir -p /opt/gitea
sudo mv /tmp/docker-compose.yml /tmp/setup.sh /opt/gitea/
sudo chmod +x /opt/gitea/setup.sh
cd /opt/gitea
docker compose up -d
sleep 10
./setup.sh
REMOTE

# ═══════════════════════════════════════════════════════════════
# DEPLOY BUP (Database backups)
# ═══════════════════════════════════════════════════════════════

log "Deploying bup"

scp -i "$SSH_KEY" \
    "$SCRIPT_DIR/bup/backup.sh" \
    "$FLEX_HOST:/opt/backup/"

ssh -i "$SSH_KEY" "$FLEX_HOST" "chmod +x /opt/backup/backup.sh"

# ═══════════════════════════════════════════════════════════════
# DEPLOY BORG (Media backups)
# ═══════════════════════════════════════════════════════════════

log "Deploying Borg"

scp -i "$SSH_KEY" \
    "$SCRIPT_DIR/borg/backup.sh" \
    "$FLEX_HOST:/opt/backup/"

ssh -i "$SSH_KEY" "$FLEX_HOST" "chmod +x /opt/backup/backup.sh"

# ═══════════════════════════════════════════════════════════════
# SETUP CRON
# ═══════════════════════════════════════════════════════════════

log "Setting up cron jobs"

ssh -i "$SSH_KEY" "$FLEX_HOST" << 'REMOTE'
# Database backup: daily at 3 AM
(crontab -l 2>/dev/null | grep -v "bup-backup"; echo "0 3 * * * /opt/backup/bup/backup.sh >> /var/log/backup-db.log 2>&1") | crontab -

# Media backup: daily at 4 AM
(crontab -l 2>/dev/null | grep -v "borg-backup"; echo "0 4 * * * /opt/backup/borg/backup.sh >> /var/log/backup-media.log 2>&1") | crontab -

echo "Cron jobs configured"
REMOTE

# ═══════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════

log "Deployment complete!"

echo ""
echo "Services on Flex VM:"
echo "  Gitea:     http://144.24.196.72:3000"
echo "  bup repo:  /backup/databases"
echo "  Borg repo: /backup/media"
echo ""
echo "Cron jobs:"
echo "  3:00 AM - Database backup (bup)"
echo "  4:00 AM - Media backup (Borg)"
echo ""
echo "To setup other servers to backup here:"
echo "  1. Copy SSH key to each server"
echo "  2. Deploy backup.sh scripts"
echo "  3. Add cron jobs"
