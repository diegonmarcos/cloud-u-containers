#!/bin/bash
# Sleep Matomo: Stop Nginx + PHP-FPM + MariaDB to free RAM
# The receiver stays running to capture tracking payloads
set -e

echo "=== Putting Matomo to sleep ==="

# Stop in reverse order of dependencies
echo "[sleep] Stopping periodic archiver..."
supervisorctl stop matomo-archiver 2>/dev/null || true

echo "[sleep] Stopping Matomo Nginx..."
supervisorctl stop matomo-nginx 2>/dev/null || true

echo "[sleep] Stopping Matomo PHP-FPM..."
supervisorctl stop matomo-php-fpm 2>/dev/null || true

echo "[sleep] Stopping MariaDB..."
supervisorctl stop mariadb 2>/dev/null || true

echo ""
echo "=== Matomo is SLEEPING ==="
echo "  Tracking payloads saved to /inbox/"
echo "  Static JS (matomo.js, /js/) still served"
echo "  UI returns 503 'sleeping' page"
echo ""
supervisorctl status
