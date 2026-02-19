#!/bin/sh
set -e
cd "$(dirname "$0")"

ENV_VARS='$SECRET_KEY $INITIAL_ADMIN_PW $RELAYUSER $RELAYPASSWORD'

echo "[init] Substituting secrets into mailu.env..."
# Read .secrets safely (avoid shell interpretation of < > $ in values)
while IFS='=' read -r _key _val; do
  case "$_key" in ""|\#*) continue ;; esac
  export "$_key=$_val"
done < .secrets
envsubst "$ENV_VARS" < mailu.env.tpl > mailu.env

# Decode DKIM private key from base64 if present in .secrets
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM private key..."
  mkdir -p dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > dkim/diegonmarcos.com.dkim.key
  chmod 600 dkim/diegonmarcos.com.dkim.key
fi

echo "[init] Done."
