#!/bin/sh
set -e
cd "$(dirname "$0")"

ENV_VARS='$ADMIN_PASSWORD $ME_PASSWORD $NOREPLY_PASSWORD $OCI_RELAYUSER $OCI_RELAYPASSWORD $AWS_RELAYUSER $AWS_RELAYPASSWORD $DKIM_PRIVATE_KEY_B64'

echo "[init] Substituting secrets into config.toml..."
while IFS='=' read -r _key _val; do
  case "$_key" in ""|\#*) continue ;; esac
  export "$_key=$_val"
done < .secrets
envsubst "$ENV_VARS" < config.toml.tpl > config.toml

# Decode DKIM private key from base64
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM private key..."
  mkdir -p dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > dkim/diegonmarcos.com.dkim.key
  chmod 600 dkim/diegonmarcos.com.dkim.key
fi

# Ensure data directory exists
mkdir -p data/db data/blobs data/acme

echo "[init] Done."
