#!/bin/bash
# Borg backup for media/large files
# Run on flex VM (local) or other servers (remote)

set -e

BACKUP_NAME="${BACKUP_NAME:-media}"
BORG_REPO="${BORG_REPO:-/backup/media/$BACKUP_NAME}"
BORG_PASSPHRASE="${BORG_PASSPHRASE:-media-backup-key}"
DATE=$(date +%Y-%m-%d)

export BORG_PASSPHRASE
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# ═══════════════════════════════════════════════════════════════
# PATHS TO BACKUP (modify per server)
# ═══════════════════════════════════════════════════════════════

BACKUP_PATHS=(
    "/home/ubuntu/photoprism/originals"
    "/home/ubuntu/photoprism/storage"
    "/var/lib/docker/volumes/mailu_data"
)

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

log "=== Borg media backup: $BACKUP_NAME ==="

# Init repo if needed
if [ ! -d "$BORG_REPO" ]; then
    log "Initializing Borg repo..."
    borg init --encryption=repokey "$BORG_REPO"
fi

# Build list of existing paths
PATHS_TO_BACKUP=""
for path in "${BACKUP_PATHS[@]}"; do
    if [ -d "$path" ]; then
        PATHS_TO_BACKUP="$PATHS_TO_BACKUP $path"
    fi
done

if [ -z "$PATHS_TO_BACKUP" ]; then
    log "No media paths found to backup"
    exit 0
fi

# Create backup
log "Creating backup..."
borg create \
    --verbose \
    --stats \
    --compression zstd,3 \
    --exclude '*.tmp' \
    --exclude '*.cache' \
    --exclude 'cache/*' \
    --exclude 'thumbnails/*' \
    "$BORG_REPO::$DATE" \
    $PATHS_TO_BACKUP

# Prune old backups
log "Pruning..."
borg prune \
    --list \
    --keep-daily=7 \
    --keep-weekly=4 \
    --keep-monthly=6 \
    "$BORG_REPO"

# Compact
borg compact "$BORG_REPO"

log "=== Backup complete ==="
borg info "$BORG_REPO"
