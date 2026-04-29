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

# ── 3. Master user — declarative password-rotation aware ──
# create_account.php is idempotent (skips on conflict), but if the
# configured pass_env value changes, the existing hm_user.hash still
# validates the OLD password and login with the new one fails. Detect
# mismatch via Hm_Auth_DB::check_credentials and DELETE the user rows
# so create_account.php recreates with the new password. apply.php
# below will then re-seed all servers/settings with the new
# encryption key (single-source-of-truth: ${PRIMARY_PASS_ENV}).
if [ -z "$PRIMARY_PASS" ] || [ "${PRIMARY_PASS#TODO_}" != "$PRIMARY_PASS" ]; then
    echo "[cypht-api] $PRIMARY_PASS_ENV unset/placeholder — skipping user creation"
    exit 0
fi

# Probe: does the new password authenticate?
PROBE_OUT=$(PHP_EMAIL="$PRIMARY_EMAIL" PHP_PASS="$PRIMARY_PASS" php -r '
require "/usr/local/share/cypht/vendor/autoload.php";
require "/usr/local/share/cypht/lib/framework.php";
$env=Hm_Environment::getInstance(); $env->load();
if(!defined("DEBUG_MODE")) define("DEBUG_MODE", false);
$cfg=new Hm_Site_Config_File(); $env->define_default_constants($cfg);
$auth=new Hm_Auth_DB($cfg);
$row=Hm_DB::execute(Hm_DB::connect($cfg), "select 1 from hm_user where username = ?", [getenv("PHP_EMAIL")]);
echo $row ? "EXISTS:" : "MISSING:";
echo $auth->check_credentials(getenv("PHP_EMAIL"), getenv("PHP_PASS")) ? "AUTH_OK" : "AUTH_FAIL";
' 2>&1 | tail -1)
echo "[cypht-api] auth probe: $PROBE_OUT"

case "$PROBE_OUT" in
    EXISTS:AUTH_FAIL)
        echo "[cypht-api] PASSWORD ROTATION detected (existing user, new pass) — dropping user rows"
        PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
            -c "DELETE FROM hm_user_session WHERE TRUE;" \
            -c "DELETE FROM hm_user_settings WHERE username = '$PRIMARY_EMAIL';" \
            -c "DELETE FROM hm_user WHERE username = '$PRIMARY_EMAIL';" 2>&1 \
            | sed 's/^/[cypht-api]   /' || true
        ;;
    EXISTS:AUTH_OK)
        echo "[cypht-api] user exists with current password — no rotation needed"
        ;;
    MISSING:*)
        echo "[cypht-api] user missing — fresh create"
        ;;
esac

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
