#!/bin/sh
set -e

# Install jq for the delivery-time mail-filter (idempotent — no-op if present).
# Upstream foxcpp/maddy is alpine-based; pulling jq at startup avoids baking a
# custom Dockerfile layer just for one package.
if ! command -v jq >/dev/null 2>&1; then
  echo "[init] Installing jq (required by mail-filter)..."
  apk add --no-cache jq >/dev/null 2>&1 || true
fi

echo "[init] Generating maddy.conf from template..."
cp /etc/maddy/maddy.conf.tpl /data/maddy.conf

# Substitute relay secrets (sed-safe: values contain no slashes/pipes)
sed -i "s|\${OCI_RELAYUSER}|$OCI_RELAYUSER|g" /data/maddy.conf
sed -i "s|\${OCI_RELAYPASSWORD}|$OCI_RELAYPASSWORD|g" /data/maddy.conf

# Write DKIM private key from base64
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM key..."
  mkdir -p /data/dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /data/dkim/@BASE_DOMAIN@.key
  chmod 600 /data/dkim/@BASE_DOMAIN@.key
fi

# Create accounts AND sync passwords on every boot.
# `creds create` errors if the account exists, so an existing account would
# keep a stale password forever (drift between secrets.yaml and the maddy
# credentials.db). Pair with `creds password` to UPSERT the secret —
# `creds create` for first-boot, `creds password` for password rotation.
# Pipe passwords via stdin — never `--password $VAR` (the value would land in
# process args / `docker top` / `ps` output). maddy's own --help carries the
# same warning. Source of every value is sops-encrypted src/secrets.yaml,
# which docker compose injects as env_file -> $ME_PASSWORD / $NOREPLY_PASSWORD.
#
# `printf '%s'` (no trailing \n) — `echo` would append a newline that maddy
# then bcrypts into the stored hash, so SMTP clients sending the bare value
# would never authenticate.
#
# Stderr stays visible so that any `creds password` failure (locked db,
# missing config block, version skew) shows up in `docker logs maddy`.
# `creds create` is expected to error on existing accounts — that's fine,
# `creds password` is the unconditional upsert.
echo "[init] Ensuring accounts + syncing passwords..."
printf '%s' "$ME_PASSWORD"      | maddy creds create   me@@BASE_DOMAIN@       2>&1 | sed 's/^/  [creds:create me]      /' || true
printf '%s' "$ME_PASSWORD"      | maddy creds password me@@BASE_DOMAIN@       2>&1 | sed 's/^/  [creds:password me]    /' || true
printf '%s' "$NOREPLY_PASSWORD" | maddy creds create   no-reply@@BASE_DOMAIN@ 2>&1 | sed 's/^/  [creds:create noreply] /' || true
printf '%s' "$NOREPLY_PASSWORD" | maddy creds password no-reply@@BASE_DOMAIN@ 2>&1 | sed 's/^/  [creds:password noreply] /' || true
maddy imap-acct create me@@BASE_DOMAIN@       2>/dev/null || true
maddy imap-acct create no-reply@@BASE_DOMAIN@ 2>/dev/null || true

echo "[init] Starting Maddy..."
exec maddy -config /data/maddy.conf run
