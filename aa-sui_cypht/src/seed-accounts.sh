#!/bin/sh
# seed-accounts.sh — idempotent pre-seed of Cypht accounts into PostgreSQL.
# Mounted into the cypht container at /opt/cypht-config/seed-accounts.sh,
# invoked by compose entrypoint BEFORE docker-entrypoint.sh starts cypht-fpm.
#
# Architecture:
#   - cypht-postgres sidecar already healthy (depends_on: service_healthy).
#   - Cypht's own setup_database.php runs on first HTTP request — we wait
#     for the user-settings table to appear (or skip silently if it doesn't).
#   - For each account in seed-accounts.json, upsert into hm_user_settings
#     with the per-account password resolved from .secrets via env_file.
#
# Failure mode: if Cypht's schema isn't what we expect (Open Question #1 in
# the plan), the seeder logs + exits 0. Accounts can still be added via UI.
set -e

CFG=/opt/cypht-config
SEED_JSON="$CFG/seed-accounts.json"
PROBE_SQL="$CFG/seed-accounts.sql"

PGHOST=127.0.0.1
PGUSER=cypht
PGDATABASE=cypht
export PGHOST PGUSER PGDATABASE PGPASSWORD="${CYPHT_DB_PASSWORD:-${POSTGRES_PASSWORD:-}}"

# ── 1. Wait for postgres to accept connections (depends_on:healthy already ensures this, belt+braces) ──
i=0
while [ $i -lt 30 ]; do
    pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
done

# ── 2. Wait for Cypht to initialize schema (setup_database.php on first hit) ──
# We give it up to 60 s. If table doesn't appear, exit 0 (non-fatal).
i=0
schema_ready=0
while [ $i -lt 60 ]; do
    out=$(psql -tA -c "SELECT to_regclass('public.hm_user_settings') IS NOT NULL" 2>/dev/null || true)
    if [ "$out" = "t" ]; then schema_ready=1; break; fi
    i=$((i + 1)); sleep 2
done

if [ "$schema_ready" != "1" ]; then
    echo "Cypht schema not ready after 120s — accounts must be added via UI."
    echo "(Cypht's setup_database.php hasn't run yet. Reseed by re-execing this script after first UI login.)"
    exit 0
fi

# ── 3. Iterate accounts and upsert ──
echo "Schema ready. Seeding accounts from $SEED_JSON ..."
seed_one() {
    acct="$1"
    email=$(echo "$acct" | jq -r .email)
    login=$(echo "$acct" | jq -r '.login // .email')
    pass_env=$(echo "$acct" | jq -r .pass_env)
    password=$(eval "printf '%s' \"\$$pass_env\"")
    if [ -z "$password" ]; then
        echo "  skip $email — env var $pass_env unset"
        return
    fi
    settings=$(jq -n --arg login "$login" --arg pwd "$password" \
                    --argjson imap "$(echo "$acct" | jq '.imap // null')" \
                    --argjson smtp "$(echo "$acct" | jq '.smtp // null')" \
                    --argjson jmap "$(echo "$acct" | jq '.jmap // null')" \
                    '{login:$login, pass:$pwd, imap:$imap, smtp:$smtp, jmap:$jmap}')

    # Upsert. EXACT column names per Cypht's schema may need adjustment after
    # first deploy — see plan Open Question #1. The conservative approach is
    # to DELETE + INSERT inside a transaction (idempotent regardless of
    # whether a unique constraint exists).
    psql -v ON_ERROR_STOP=1 <<SQL >/dev/null
BEGIN;
DELETE FROM hm_user_settings WHERE username = '$email';
INSERT INTO hm_user_settings (username, settings) VALUES ('$email', '$settings'::jsonb);
COMMIT;
SQL
    echo "  seeded $email"
}

# Primary
primary=$(jq -c .primary "$SEED_JSON")
seed_one "$primary"

# Extras
jq -c '.extras[]' "$SEED_JSON" | while read -r acct; do
    seed_one "$acct"
done

echo "Seed complete."
