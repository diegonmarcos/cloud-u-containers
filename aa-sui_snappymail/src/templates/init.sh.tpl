#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

ENV_VARS='$SNAPPYMAIL_ADMIN_PASSWORD'

echo "[init] Substituting secrets into application.ini..."
set -a
. ../.secrets
set +a
envsubst "$ENV_VARS" < application.ini.tpl > application.ini

echo "[init] Done — configs mounted directly into container via bind mounts."
