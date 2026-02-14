#!/bin/bash
# Wake Matomo: Start MariaDB + PHP-FPM + Nginx, import inbox payloads
set -e

echo "=== Waking Matomo ==="

# ─── Start MariaDB ──────────────────────────────────────────────────────────

echo "[wake] Starting MariaDB..."
supervisorctl start mariadb

# Wait for MariaDB to be ready (max 30 seconds)
echo "[wake] Waiting for MariaDB..."
for i in $(seq 1 30); do
    if mariadb -u "${MATOMO_DATABASE_USERNAME:-matomo}" -p"${MATOMO_DATABASE_PASSWORD}" -e "SELECT 1" --socket=/run/mysqld/mysqld.sock >/dev/null 2>&1; then
        echo "[wake] MariaDB ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[wake] ERROR: MariaDB failed to start after 30 seconds"
        exit 1
    fi
    sleep 1
done

# ─── Run pending database migrations ──────────────────────────────────────

echo "[wake] Checking for pending Matomo updates..."
php -d memory_limit=512M \
    /var/www/html/console core:update --yes 2>&1 || {
    echo "[wake] No pending updates (or update had errors)"
}
chown -R www-data:www-data /var/www/html

# ─── Start Matomo services ──────────────────────────────────────────────────

echo "[wake] Starting Matomo PHP-FPM..."
supervisorctl start matomo-php-fpm

echo "[wake] Starting Matomo Nginx..."
supervisorctl start matomo-nginx

# Wait for Matomo Nginx to be ready
for i in $(seq 1 10); do
    if curl -sf http://127.0.0.1:8081/ >/dev/null 2>&1; then
        echo "[wake] Matomo Nginx ready on port 8081"
        break
    fi
    sleep 1
done

# ─── Import buffered tracking payloads ──────────────────────────────────────

INBOX_COUNT=$(find /inbox -name '*.json' 2>/dev/null | wc -l)
if [ "$INBOX_COUNT" -gt 0 ]; then
    echo "[wake] Importing $INBOX_COUNT buffered tracking payloads..."
    /scripts/import-inbox.sh
else
    echo "[wake] No buffered payloads to import"
fi

# ─── Run initial archiving ─────────────────────────────────────────────────

echo "[wake] Running initial Matomo archiving..."
php -d memory_limit=512M \
    /var/www/html/console core:archive --force-all-websites 2>&1 || {
    echo "[wake] WARNING: Archiving had errors (non-fatal)"
}

# ─── Start periodic archiver ──────────────────────────────────────────────

echo "[wake] Starting periodic archiver (every 30 min)..."
supervisorctl start matomo-archiver

# ─── Status ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Matomo is AWAKE ==="
echo "  UI:       http://127.0.0.1:8080/"
echo "  Internal: http://127.0.0.1:8081/"
echo ""
supervisorctl status
