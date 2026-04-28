#!/bin/sh
# seed-accounts.sh — bootstrap Cypht's master user + 5 mail backends.
#
# Mounted into the cypht container at /tmp/cypht-config/seed-accounts.sh,
# invoked by compose entrypoint BEFORE docker-entrypoint.sh starts cypht-fpm.
#
# Pipeline:
#   1. Wait for cypht-postgres healthcheck (30s budget).
#   2. Run Cypht's setup_database.php to create the schema (hm_user,
#      hm_user_session, hm_user_settings tables).
#   3. Run Cypht's create_account.php — creates the master user
#      "me@diegonmarcos.com" with password from $ME_PASSWORD env var.
#      (Idempotent: scripts/create_account.php skips on conflict.)
#   4. Run our seed-accounts.php — encrypts and persists 5 IMAP/SMTP/JMAP
#      backends (from seed-accounts.json) into hm_user_settings.settings.
#      Uses Cypht's own Hm_User_Config_DB so the encryption key matches
#      what Cypht expects on login (the user's plaintext password — see
#      lib/config.php::save).
#
# Failure modes (all non-fatal — exit 0):
#   * Schema creation fails → cypht's web entrypoint will retry on first
#     request.
#   * create_account.php returns "already exists" → fine, idempotent.
#   * seed-accounts.php detects placeholder TODO_* secrets → skips the
#     extras silently; primary user is still usable for manual UI add.

set -e

CFG=/tmp/cypht-config
APP=/usr/local/share/cypht

PGHOST=127.0.0.1
PGUSER=cypht
PGDATABASE=cypht
export PGHOST PGUSER PGDATABASE PGPASSWORD="${CYPHT_DB_PASSWORD:-${POSTGRES_PASSWORD:-}}"

# ── 1. Wait for postgres to accept connections ──
# pg_isready (postgresql-client) + jq are both apt-installed in our
# Dockerfile so they're guaranteed available. Compose `depends_on:
# service_healthy` already gates this start; the 30s budget is a safety net.
i=0
while [ $i -lt 30 ]; do
    pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
done
if ! pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1; then
    echo "postgres not reachable on 127.0.0.1:5432 after 30s — skipping seed (cypht web entrypoint will retry)"
    exit 0
fi
echo "postgres reachable — proceeding"

# ── 2. Initialize Cypht schema (idempotent — has IF NOT EXISTS guards) ──
echo "Running setup_database.php..."
cd "$APP" || { echo "cypht install dir missing"; exit 0; }
php scripts/setup_database.php 2>&1 | sed 's/^/  /' || {
    echo "setup_database.php failed — schema may not be ready, exiting non-fatal"
    exit 0
}

# ── 3. Create master user account ──
PRIMARY_EMAIL=$(jq -r .primary.email "$CFG/seed-accounts.json")
PRIMARY_PASS_ENV=$(jq -r .primary.pass_env "$CFG/seed-accounts.json")
PRIMARY_PASS=$(eval "printf '%s' \"\$$PRIMARY_PASS_ENV\"")

if [ -z "$PRIMARY_PASS" ]; then
    echo "primary password env $PRIMARY_PASS_ENV unset — skipping user creation"
    exit 0
fi

echo "Creating user account: $PRIMARY_EMAIL ..."
php scripts/create_account.php "$PRIMARY_EMAIL" "$PRIMARY_PASS" 2>&1 | sed 's/^/  /' || true

# ── 4. Seed the 5 IMAP/SMTP/JMAP backends ──
# Uses Cypht's own Hm_User_Config_DB → hm_user_settings.settings, encrypted
# with the user's plaintext password (same key Cypht uses on login). Server
# entries are stored under imap_servers / smtp_servers / jmap_servers in
# the user's config blob.
SEEDER_PHP=/tmp/cypht-config/seed-accounts.php
if [ -f "$SEEDER_PHP" ]; then
    echo "Seeding mail backends from seed-accounts.json ..."
    php "$SEEDER_PHP" 2>&1 | sed 's/^/  /' || true
else
    echo "seed-accounts.php missing — skipping backend seed"
fi

echo ""
echo "Seed complete. Log in at https://webmail.diegonmarcos.com with $PRIMARY_EMAIL"
