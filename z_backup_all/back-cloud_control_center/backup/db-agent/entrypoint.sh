#!/bin/bash
# db-agent: Central database backup service
# Runs on each VM, auto-detects databases, dumps them, logs everything
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════

VM_NAME="${VM_NAME:-$(hostname)}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"
LOG_DIR="${LOG_DIR:-/var/log/db-agent}"
SCHEDULE="${SCHEDULE:-0 3 * * *}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-backup}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
BUP_REMOTE="${BUP_REMOTE:-}"
RUN_ONCE="${RUN_ONCE:-false}"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# ═══════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════

LOGFILE="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$VM_NAME] $1"
    echo "$msg" | tee -a "$LOGFILE"
}

log_ok()   { log "OK    $1"; }
log_skip() { log "SKIP  $1"; }
log_fail() { log "FAIL  $1"; }

# ═══════════════════════════════════════════════════════════════
# NOTIFY
# ═══════════════════════════════════════════════════════════════

notify() {
    local title="$1" body="$2" priority="${3:-default}"
    if [ -n "$NTFY_URL" ]; then
        curl -sf \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: floppy_disk" \
            -d "$body" \
            "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
    fi
}

# ═══════════════════════════════════════════════════════════════
# DUMP FUNCTIONS
# ═══════════════════════════════════════════════════════════════

dump_sqlite() {
    local container="$1" db_path="$2" label="$3"
    local outfile="$BACKUP_DIR/${label}.sqlite"
    log "SQLite: $container → $label"
    if docker exec "$container" sqlite3 "$db_path" ".backup '/tmp/dump.db'" 2>/dev/null && \
       docker cp "$container:/tmp/dump.db" "$outfile" 2>/dev/null; then
        docker exec "$container" rm -f /tmp/dump.db 2>/dev/null || true
        local size=$(du -h "$outfile" 2>/dev/null | cut -f1)
        log_ok "$label ($size)"
        return 0
    else
        log_fail "$label"
        return 1
    fi
}

dump_postgres() {
    local container="$1" db="$2" user="$3" label="$4"
    local outfile="$BACKUP_DIR/${label}.sql"
    log "Postgres: $container/$db → $label"
    if docker exec "$container" pg_dump -U "$user" "$db" > "$outfile" 2>/dev/null; then
        local size=$(du -h "$outfile" 2>/dev/null | cut -f1)
        log_ok "$label ($size)"
        return 0
    else
        log_fail "$label"
        return 1
    fi
}

dump_mariadb() {
    local container="$1" db="$2" label="$3"
    local outfile="$BACKUP_DIR/${label}.sql"
    log "MariaDB: $container/$db → $label"
    if docker exec "$container" mysqldump -u root "$db" > "$outfile" 2>/dev/null; then
        local size=$(du -h "$outfile" 2>/dev/null | cut -f1)
        log_ok "$label ($size)"
        return 0
    else
        log_fail "$label"
        return 1
    fi
}

dump_redis() {
    local container="$1" label="$2"
    local outfile="$BACKUP_DIR/${label}.rdb"
    log "Redis: $container → $label"
    docker exec "$container" redis-cli BGSAVE >/dev/null 2>&1 || true
    sleep 2
    if docker cp "$container:/data/dump.rdb" "$outfile" 2>/dev/null; then
        local size=$(du -h "$outfile" 2>/dev/null | cut -f1)
        log_ok "$label ($size)"
        return 0
    else
        log_fail "$label"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# AUTO-DETECT & BACKUP
# ═══════════════════════════════════════════════════════════════

run_backup() {
    local start_time=$(date +%s)
    local ok=0 fail=0 skip=0

    log "════════════════════════════════════════"
    log "Backup started: $VM_NAME"
    log "════════════════════════════════════════"

    # Detect running containers and back up known databases
    for container in $(docker ps --format '{{.Names}}' 2>/dev/null | sort); do
        case "$container" in
            # SQLite databases
            npm)
                dump_sqlite "$container" "/data/database.sqlite" "npm" && ((ok++)) || ((fail++)) ;;
            vaultwarden)
                dump_sqlite "$container" "/data/db.sqlite3" "vaultwarden" && ((ok++)) || ((fail++)) ;;
            authelia)
                dump_sqlite "$container" "/config/db.sqlite3" "authelia" && ((ok++)) || ((fail++)) ;;
            ntfy)
                dump_sqlite "$container" "/var/cache/ntfy/cache.db" "ntfy" && ((ok++)) || ((fail++)) ;;
            stalwart-mail)
                dump_sqlite "$container" "/opt/stalwart-mail/data/index.sqlite3" "stalwart" && ((ok++)) || ((fail++)) ;;

            # PostgreSQL databases
            nocodb-db|nocodb_postgres)
                dump_postgres "$container" "nocodb" "nocodb" "$container" && ((ok++)) || ((fail++)) ;;
            etherpad_postgres)
                dump_postgres "$container" "etherpad" "etherpad" "etherpad" && ((ok++)) || ((fail++)) ;;
            hedgedoc_postgres)
                dump_postgres "$container" "hedgedoc" "hedgedoc" "hedgedoc" && ((ok++)) || ((fail++)) ;;
            windmill-db)
                dump_postgres "$container" "windmill" "postgres" "windmill" && ((ok++)) || ((fail++)) ;;

            # MariaDB databases
            photoprism-db|photoprism_mariadb)
                dump_mariadb "$container" "photoprism" "$container" && ((ok++)) || ((fail++)) ;;
            matomo-db)
                dump_mariadb "$container" "matomo" "matomo" && ((ok++)) || ((fail++)) ;;
            matomo-hybrid)
                dump_mariadb "$container" "matomo" "matomo-hybrid" && ((ok++)) || ((fail++)) ;;

            # Redis
            authelia-redis|redis)
                dump_redis "$container" "$container" && ((ok++)) || ((fail++)) ;;

            # Not a database container
            *)
                ((skip++)) || true ;;
        esac
    done

    # ═══════════════════════════════════════════════════════════
    # BUP (if remote configured)
    # ═══════════════════════════════════════════════════════════

    if [ -n "$BUP_REMOTE" ]; then
        log "bup: indexing dumps..."
        export BUP_DIR="$BUP_REMOTE"
        if bup index "$BACKUP_DIR" 2>>"$LOGFILE" && \
           bup save -n "$VM_NAME" "$BACKUP_DIR" 2>>"$LOGFILE"; then
            log_ok "bup save → $VM_NAME"
        else
            log_fail "bup save"
            ((fail++))
        fi
    fi

    # ═══════════════════════════════════════════════════════════
    # RETENTION: clean old local dumps
    # ═══════════════════════════════════════════════════════════

    local cleaned=$(find "$BACKUP_DIR" -name "*.sqlite" -o -name "*.sql" -o -name "*.rdb" | \
        xargs -r ls -t 2>/dev/null | tail -n +$((RETENTION_DAYS + 1)) | wc -l)
    find "$BACKUP_DIR" \( -name "*.sqlite" -o -name "*.sql" -o -name "*.rdb" \) \
        -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

    # Clean old logs (keep 30 days)
    find "$LOG_DIR" -name "backup-*.log" -mtime +30 -delete 2>/dev/null || true

    # ═══════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════

    local elapsed=$(( $(date +%s) - start_time ))
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

    log "════════════════════════════════════════"
    log "Backup complete: ${ok} OK, ${fail} FAIL (${elapsed}s)"
    log "Local: $BACKUP_DIR ($total_size)"
    log "════════════════════════════════════════"

    # Write machine-readable status
    cat > "$LOG_DIR/last-run.json" <<EOF
{"vm":"$VM_NAME","ts":"$(date -Iseconds)","ok":$ok,"fail":$fail,"skip":$skip,"elapsed":${elapsed},"size":"$total_size"}
EOF

    # Notify
    if [ "$fail" -gt 0 ]; then
        notify "Backup $VM_NAME" "${ok} OK, ${fail} FAIL (${elapsed}s)" "high"
    else
        notify "Backup $VM_NAME" "${ok} OK (${elapsed}s)" "low"
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN: run once or schedule via cron
# ═══════════════════════════════════════════════════════════════

log "db-agent starting on $VM_NAME"
log "Schedule: $SCHEDULE | Retention: ${RETENTION_DAYS}d"

if [ "$RUN_ONCE" = "true" ]; then
    run_backup
    exit 0
fi

# Write cron entry and run via crond
echo "$SCHEDULE /usr/local/bin/entrypoint.sh" > /etc/crontabs/root
export RUN_ONCE=true

# Run first backup immediately, then hand off to cron
run_backup

log "Handing off to cron ($SCHEDULE)..."
exec crond -f -l 2
