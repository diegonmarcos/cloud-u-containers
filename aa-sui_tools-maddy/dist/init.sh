#!/bin/sh
set -e

echo "[init] Generating maddy.conf from template..."
cp /etc/maddy/maddy.conf.tpl /data/maddy.conf

# Substitute relay secrets
sed -i "s|\${OCI_RELAYUSER}|$OCI_RELAYUSER|g" /data/maddy.conf
sed -i "s|\${OCI_RELAYPASSWORD}|$OCI_RELAYPASSWORD|g" /data/maddy.conf

# Write DKIM private key from base64
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM key..."
  mkdir -p /data/dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /data/dkim/diegonmarcos.com.key
  chmod 600 /data/dkim/diegonmarcos.com.key
fi

# Create accounts (idempotent — errors ignored if already exist)
echo "[init] Ensuring accounts..."
echo "$ME_PASSWORD" | maddy creds create me@diegonmarcos.com 2>/dev/null || true
echo "$NOREPLY_PASSWORD" | maddy creds create no-reply@diegonmarcos.com 2>/dev/null || true
maddy imap-acct create me@diegonmarcos.com 2>/dev/null || true
maddy imap-acct create no-reply@diegonmarcos.com 2>/dev/null || true

echo "[init] Starting Maddy..."
exec maddy -config /data/maddy.conf run
