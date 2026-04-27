#!/usr/bin/env bash
# Pre-hook: runs on the host (oci-mail) AFTER engine has rendered configs/cypht.env
# from templates/cypht.env.tpl with @VAR@ substitution at build time.
# Only runtime ${VAR} placeholders for sops secrets remain — substitute them
# in-place from .secrets before the image boots.
set -e
cd "$(dirname "$0")"

ENV_VARS='$CYPHT_DB_PASSWORD $POSTGRES_PASSWORD $CYPHT_2FA_SECRET $CYPHT_ADMIN_PASSWORD'

echo "[init] Substituting runtime secrets into cypht.env..."
set -a
. ../.secrets
# Defensive defaults — if a secret is missing, leave a recognizable placeholder
# rather than empty string (cypht will fail noisier).
: "${CYPHT_DB_PASSWORD:=__MISSING_CYPHT_DB_PASSWORD__}"
: "${POSTGRES_PASSWORD:=$CYPHT_DB_PASSWORD}"
: "${CYPHT_2FA_SECRET:=__MISSING_CYPHT_2FA_SECRET__}"
: "${CYPHT_ADMIN_PASSWORD:=__MISSING_CYPHT_ADMIN_PASSWORD__}"
set +a

[ -f cypht.env ] && envsubst "$ENV_VARS" < cypht.env > cypht.env.tmp && mv cypht.env.tmp cypht.env

echo "[init] Done — cypht.env ready for container mount."
