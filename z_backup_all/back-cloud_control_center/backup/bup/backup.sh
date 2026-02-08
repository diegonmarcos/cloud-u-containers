#!/bin/bash
# bup backup script - dumps databases and backs up to flex
# Run on each server via cron

set -e

# ═══════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════

BACKUP_NAME="${BACKUP_NAME:-$(hostname)}"
BUP_DIR="${BUP_DIR:-ssh://root@144.24.196.72:2223/backup/databases}"
STAGING="/tmp/db-dumps"
DATE=$(date +%Y-%m-%d)

export BUP_DIR

# ═══════════════════════════════════════════════════════════════
# FUNCTIONS
# ═══════════════════════════════════════════════════════════════

log() { echo "[$(date '+%H:%M:%S')] $1"; }

dump_sqlite() {
    local container=$1 db_path=$2 output=$3
    log "SQLite: $container"
    docker exec "$container" sqlite3 "$db_path" ".backup '/tmp/dump.db'" 2>/dev/null && \
        docker cp "$container:/tmp/dump.db" "$output" && \
        docker exec "$container" rm /tmp/dump.db || log "  skip"
}

dump_postgres() {
    local container=$1 db=$2 user=$3 output=$4
    log "Postgres: $container/$db"
    docker exec "$container" pg_dump -U "$user" "$db" > "$output" 2>/dev/null || log "  skip"
}

dump_mariadb() {
    local container=$1 db=$2 output=$3
    log "MariaDB: $container/$db"
    docker exec "$container" mysqldump -u root "$db" > "$output" 2>/dev/null || log "  skip"
}

dump_redis() {
    local container=$1 output=$2
    log "Redis: $container"
    docker exec "$container" redis-cli BGSAVE >/dev/null 2>&1
    sleep 2
    docker cp "$container:/data/dump.rdb" "$output" 2>/dev/null || log "  skip"
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

log "=== Database backup: $BACKUP_NAME ==="

rm -rf "$STAGING" && mkdir -p "$STAGING"

# Detect and dump running databases
docker ps --format '{{.Names}}' | while read container; do
    case "$container" in
        npm|sqlite-npm)
            dump_sqlite "$container" "/data/database.sqlite" "$STAGING/npm.sqlite" ;;
        vaultwarden|sqlite-vaultwarden)
            dump_sqlite "$container" "/data/db.sqlite3" "$STAGING/vaultwarden.sqlite" ;;
        authelia)
            dump_sqlite "$container" "/config/db.sqlite3" "$STAGING/authelia.sqlite" ;;
        nocodb-db)
            dump_postgres "$container" "nocodb" "nocodb" "$STAGING/nocodb.sql" ;;
        matomo-db)
            dump_mariadb "$container" "matomo" "$STAGING/matomo.sql" ;;
        photoprism-db)
            dump_mariadb "$container" "photoprism" "$STAGING/photoprism.sql" ;;
        *redis*)
            dump_redis "$container" "$STAGING/${container}.rdb" ;;
    esac
done

# Skip if no dumps
if [ -z "$(ls -A $STAGING 2>/dev/null)" ]; then
    log "No databases found to backup"
    exit 0
fi

# bup backup
log "Running bup..."
bup index "$STAGING"
bup save -n "$BACKUP_NAME" "$STAGING"

# Cleanup
rm -rf "$STAGING"

log "=== Backup complete ==="
