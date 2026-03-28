#!/bin/sh
set -e
cd "$(dirname "$0")"

ENV_VARS='$SNAPPYMAIL_ADMIN_PASSWORD'

echo "[init] Substituting secrets into application.ini..."
while IFS='=' read -r _key _val; do
  case "$_key" in ""|\#*) continue ;; esac
  export "$_key=$_val"
done < .secrets
envsubst "$ENV_VARS" < config/application.ini.tpl > config/application.ini

echo "[init] Done — configs mounted directly into container via named volume overlays."
