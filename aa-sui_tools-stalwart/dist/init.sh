#!/bin/sh
set -e

ENV_VARS='$ADMIN_PASSWORD $ME_PASSWORD $NOREPLY_PASSWORD $OCI_RELAYUSER $OCI_RELAYPASSWORD $AWS_RELAYUSER $AWS_RELAYPASSWORD $DKIM_PRIVATE_KEY_B64 $CF_DNS_API_TOKEN'

echo "[init] Substituting secrets into config.toml..."
envsubst "$ENV_VARS" < /opt/stalwart-mail/etc/config.toml.tpl > /opt/stalwart-mail/etc/config.toml

# Decode DKIM private key from base64
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM private key..."
  mkdir -p /opt/stalwart-mail/dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /opt/stalwart-mail/dkim/diegonmarcos.com.dkim.key
  chmod 600 /opt/stalwart-mail/dkim/diegonmarcos.com.dkim.key
fi

echo "[init] Starting Stalwart..."
exec /usr/local/bin/stalwart-mail --config /opt/stalwart-mail/etc/config.toml
