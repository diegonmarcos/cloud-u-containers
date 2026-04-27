#!/bin/sh
# seed-accounts.sh — bootstrap Cypht's master user account.
#
# Mounted into the cypht container at /opt/cypht-config/seed-accounts.sh,
# invoked by compose entrypoint BEFORE docker-entrypoint.sh starts cypht-fpm.
#
# What this seeder DOES:
#   1. Wait for cypht-postgres healthcheck.
#   2. Run Cypht's setup_database.php to create the schema (hm_user,
#      hm_user_session, hm_user_settings tables).
#   3. Run Cypht's create_account.php to create the master user account
#      "me@diegonmarcos.com" with password from $ME_PASSWORD env var.
#      (Idempotent — skips if user already exists.)
#
# What this seeder does NOT do (Cypht limitation, not laziness):
#   * IMAP/SMTP/JMAP server entries are stored in hm_user_settings.settings
#     as an encrypted BYTEA. The encryption key is derived from the user's
#     master password. We CAN'T inject server configs server-side without
#     impersonating an authenticated session.
#
# After this seeder runs:
#   * Log in once at https://webmail.diegonmarcos.com with
#     username = me@diegonmarcos.com, password = $ME_PASSWORD
#   * Use the "Servers" page to add the 5 IMAP/JMAP/SMTP backends
#     declared in seed-accounts.json. The corresponding passwords from
#     .secrets are documented in secrets.schema.md.
#
# Failure modes:
#   * Schema creation fails → exit 0, log error. Cypht's web entrypoint
#     will retry on first request.
#   * User creation fails → exit 0, log error. Manual fallback: log into
#     Cypht (no users yet → first user becomes admin).

set -e

CFG=/opt/cypht-config
APP=/usr/local/share/cypht

PGHOST=127.0.0.1
PGUSER=cypht
PGDATABASE=cypht
export PGHOST PGUSER PGDATABASE PGPASSWORD="${CYPHT_DB_PASSWORD:-${POSTGRES_PASSWORD:-}}"

# ── 1. Wait for postgres to accept connections ──
i=0
while [ $i -lt 30 ]; do
    pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
done
if ! pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1; then
    echo "postgres not reachable — skipping seed (cypht web entrypoint will retry)"
    exit 0
fi

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

echo ""
echo "Seed complete. To finish setup:"
echo "  1. Visit https://webmail.diegonmarcos.com"
echo "  2. Log in with $PRIMARY_EMAIL + the password from \$$PRIMARY_PASS_ENV"
echo "  3. Open Servers page; add the 5 backends from seed-accounts.json"
echo "     (passwords for each in /run/secrets/<KEY> or env vars)"
