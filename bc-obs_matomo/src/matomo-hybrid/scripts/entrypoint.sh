#!/bin/bash
# Matomo Hybrid Container Entrypoint
# Initializes Matomo files and MariaDB data directory if needed

set -e

echo "[entrypoint] Starting matomo-hybrid container..."

# ═══════════════════════════════════════════════════════════════════════════════
# Initialize Matomo files if volume is empty
# ═══════════════════════════════════════════════════════════════════════════════

if [ ! -f /var/www/html/matomo.php ]; then
    echo "[entrypoint] Matomo files not found, copying from source..."
    cp -rn /usr/src/matomo/. /var/www/html/
    chown -R www-data:www-data /var/www/html
    echo "[entrypoint] Matomo files initialized"
else
    echo "[entrypoint] Matomo files already present (volume data preserved)"
fi

# Ensure correct ownership
chown -R www-data:www-data /var/www/html /inbox

# ═══════════════════════════════════════════════════════════════════════════════
# Initialize MariaDB data directory if empty
# ═══════════════════════════════════════════════════════════════════════════════

if [ ! -d /var/lib/mysql/mysql ]; then
    echo "[entrypoint] MariaDB data directory empty, initializing..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
    echo "[entrypoint] MariaDB initialized"

    # Start MariaDB temporarily to create the database and user
    mariadbd --user=mysql &
    MARIADB_PID=$!

    # Wait for MariaDB to be ready
    for i in $(seq 1 30); do
        if mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
            break
        fi
        echo "[entrypoint] Waiting for MariaDB to start... ($i/30)"
        sleep 1
    done

    # Create database and user
    DB_NAME="${MATOMO_DATABASE_DBNAME:-matomo}"
    DB_USER="${MATOMO_DATABASE_USERNAME:-matomo}"
    DB_PASS="${MATOMO_DATABASE_PASSWORD:-changeme}"

    mariadb -u root <<-EOSQL
        CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
        GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
EOSQL

    echo "[entrypoint] Database '${DB_NAME}' and user '${DB_USER}' created"

    # Stop temporary MariaDB
    kill "$MARIADB_PID"
    wait "$MARIADB_PID" 2>/dev/null || true
    echo "[entrypoint] MariaDB initialization complete"
else
    echo "[entrypoint] MariaDB data already present (volume data preserved)"
fi

# Ensure MariaDB socket directory and data have correct permissions
# (volume files may be owned by a different UID from the old container)
chown mysql:mysql /run/mysqld
chown -R mysql:mysql /var/lib/mysql

# ═══════════════════════════════════════════════════════════════════════════════
# Update Matomo config.ini.php database host to localhost
# ═══════════════════════════════════════════════════════════════════════════════

CONFIG_FILE="/var/www/html/config/config.ini.php"
if [ -f "$CONFIG_FILE" ]; then
    # Replace any Docker hostname with localhost (for hybrid container)
    sed -i 's/^host = .*/host = "localhost"/' "$CONFIG_FILE"
    # Ensure socket path for MariaDB local connection
    if ! grep -q "unix_socket" "$CONFIG_FILE" 2>/dev/null; then
        sed -i '/^\[database\]/a unix_socket = "/run/mysqld/mysqld.sock"' "$CONFIG_FILE"
    fi

    # Disable browser-triggered archiving (use cron-based archiver instead)
    # This prevents the "Oops" timeout errors on the 1GB RAM VM
    if grep -q "enable_browser_archiving_triggering" "$CONFIG_FILE" 2>/dev/null; then
        sed -i 's/^enable_browser_archiving_triggering = .*/enable_browser_archiving_triggering = 0/' "$CONFIG_FILE"
    else
        sed -i '/^\[General\]/a enable_browser_archiving_triggering = 0' "$CONFIG_FILE"
    fi

    # Enable auto-update (check + apply via console and UI)
    if grep -q "enable_auto_update" "$CONFIG_FILE" 2>/dev/null; then
        sed -i 's/^enable_auto_update = .*/enable_auto_update = 1/' "$CONFIG_FILE"
    else
        sed -i '/^\[General\]/a enable_auto_update = 1' "$CONFIG_FILE"
    fi

    # Enable update email notifications
    if grep -q "enable_update_communication" "$CONFIG_FILE" 2>/dev/null; then
        sed -i 's/^enable_update_communication = .*/enable_update_communication = 1/' "$CONFIG_FILE"
    else
        sed -i '/^\[General\]/a enable_update_communication = 1' "$CONFIG_FILE"
    fi

    echo "[entrypoint] config.ini.php updated for local database, archiving, and auto-update"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Start supervisor (runs receiver-nginx + receiver-php-fpm by default)
# ═══════════════════════════════════════════════════════════════════════════════

echo "[entrypoint] Launching supervisord..."
exec "$@"
