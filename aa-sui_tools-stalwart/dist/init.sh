#!/bin/sh
set -e
cd "$(dirname "$0")"

# Stop Mailu if still running (migration from Mailu → Stalwart)
if [ -f /opt/mailu/docker-compose.yml ]; then
  echo "[init] Stopping Mailu (migration to Stalwart)..."
  (cd /opt/mailu && docker compose down 2>/dev/null) || true
fi

ENV_VARS='$ADMIN_PASSWORD $ME_PASSWORD $NOREPLY_PASSWORD $OCI_RELAYUSER $OCI_RELAYPASSWORD $AWS_RELAYUSER $AWS_RELAYPASSWORD $DKIM_PRIVATE_KEY_B64 $CF_DNS_API_TOKEN'

echo "[init] Substituting secrets into config.toml..."
while IFS='=' read -r _key _val; do
  case "$_key" in ""|\#*) continue ;; esac
  export "$_key=$_val"
done < .secrets
envsubst "$ENV_VARS" < config.toml.tpl > config.toml

# Clear ACME data if domains changed (forces new cert with all SANs)
ACME_DOMAINS="mail.diegonmarcos.com,imap.diegonmarcos.com,smtp.diegonmarcos.com"
ACME_STAMP="data/.acme-domains"
if [ -f "$ACME_STAMP" ]; then
  OLD_DOMAINS=$(cat "$ACME_STAMP")
  if [ "$OLD_DOMAINS" != "$ACME_DOMAINS" ]; then
    echo "[init] ACME domains changed — clearing cert cache for re-issue"
    rm -rf data/acme
  fi
fi
echo "$ACME_DOMAINS" > "$ACME_STAMP"

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
