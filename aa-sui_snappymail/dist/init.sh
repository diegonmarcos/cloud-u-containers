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

# Copy configs into data volume (avoids bind-mount conflicts with entrypoint sed)
# Data dir owned by uid 82 (snappymail) — use sudo
sudo mkdir -p data/_data_/_default_/configs data/_data_/_default_/domains
sudo cp config/application.ini data/_data_/_default_/configs/application.ini
sudo cp config/domains/*.ini data/_data_/_default_/domains/
sudo chown -R 82:82 data/

echo "[init] Done."
