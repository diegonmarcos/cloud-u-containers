#!/bin/sh
# cypht-api/sidecar.sh — declarative-config bootstrap for the cypht container.
#
# Mounted at /tmp/cypht-config/cypht-api/sidecar.sh, invoked by the compose
# entrypoint BEFORE docker-entrypoint.sh starts cypht-fpm:
#
#   compose entrypoint:
#     /tmp/cypht-config/cypht-api/sidecar.sh && exec docker-entrypoint.sh
#
# Pipeline (idempotent — safe to re-run on every container start):
#   1. Wait for postgres on 127.0.0.1:5432 (pg_isready, 30s budget).
#   2. Run cypht's setup_database.php → creates hm_user / hm_user_session /
#      hm_user_settings tables + runs migrations.
#   3. Run cypht's create_account.php → creates the master user (idempotent;
#      script returns "already exists" on rerun).
#   4. Run our apply.php → reads configs.json, applies all sections via
#      Hm_User_Config_DB. Single save() per run.
#
# Failure modes (all non-fatal — exit 0):
#   * postgres unreachable        → skip; cypht web entrypoint retries
#   * setup_database.php errors    → skip; cypht web entrypoint will recreate
#   * create_account.php conflict  → fine, idempotent
#   * apply.php detects placeholders → skips that section silently
#
# pg_isready and jq are provisioned by build.json#docker.runtime_packages.apt
# so they're always present in the rebuilt cypht-binaries image.
set -e

CFG_DIR=/tmp/cypht-config/cypht-api
APP_DIR=/usr/local/share/cypht

PGHOST=127.0.0.1
PGUSER=cypht
PGDATABASE=cypht
export PGHOST PGUSER PGDATABASE PGPASSWORD="${CYPHT_DB_PASSWORD:-${POSTGRES_PASSWORD:-}}"

# Resolve primary user/email from configs.json (single source of truth)
# so subsequent modules can use $PRIMARY_EMAIL and $ME_PASSWORD-derivative envs.
PRIMARY_EMAIL=$(jq -r '.primary_user.email // empty' "$CFG_DIR/configs.json")
PRIMARY_PASS_ENV=$(jq -r '.primary_user.pass_env // "ME_PASSWORD"' "$CFG_DIR/configs.json")
PRIMARY_PASS=$(eval "printf '%s' \"\$$PRIMARY_PASS_ENV\"")
export PRIMARY_EMAIL

echo "[cypht-api] primary_email=$PRIMARY_EMAIL pass_env=$PRIMARY_PASS_ENV"

# ── 1. Wait for postgres ─────────────────────────────────────────────
i=0
while [ $i -lt 30 ]; do
    pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
done
if ! pg_isready -h "$PGHOST" -U "$PGUSER" >/dev/null 2>&1; then
    echo "[cypht-api] postgres not reachable after 30s — skipping (cypht entrypoint will retry)"
    exit 0
fi
echo "[cypht-api] postgres reachable — proceeding"

# ── 2. Schema (idempotent; setup_database.php has IF NOT EXISTS guards) ──
cd "$APP_DIR" || { echo "[cypht-api] cypht install dir missing"; exit 0; }
echo "[cypht-api] running setup_database.php"
php scripts/setup_database.php 2>&1 | sed 's/^/[cypht-api]   /' || {
    echo "[cypht-api] setup_database.php errored — non-fatal, skipping"
    exit 0
}

# ── 3. Master user (idempotent; create_account.php skips on conflict) ──
if [ -z "$PRIMARY_PASS" ] || [ "${PRIMARY_PASS#TODO_}" != "$PRIMARY_PASS" ]; then
    echo "[cypht-api] $PRIMARY_PASS_ENV unset/placeholder — skipping user creation"
    exit 0
fi
echo "[cypht-api] running create_account.php for $PRIMARY_EMAIL"
php scripts/create_account.php "$PRIMARY_EMAIL" "$PRIMARY_PASS" 2>&1 | sed 's/^/[cypht-api]   /' || true

# ── 4. Apply declarative config (accounts + carddav + feeds + settings) ──
if [ ! -f "$CFG_DIR/apply.php" ]; then
    echo "[cypht-api] apply.php missing — skipping declarative config"
    exit 0
fi
echo "[cypht-api] running apply.php"
php "$CFG_DIR/apply.php" 2>&1 | sed 's/^/[cypht-api]   /' || true

echo "[cypht-api] done — log in at https://webmail.diegonmarcos.com/"
exit 0
