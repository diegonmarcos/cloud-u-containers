#!/bin/sh
set -e

echo "[init] Writing secrets to files for {{ secret }} template..."

# Write each env var to a file — {{ secret "/path" }} reads raw bytes (safe for $)
mkdir -p /tmp/.secrets.d
for var in \
  AUTHELIA_JWT_SECRET \
  AUTHELIA_SESSION_SECRET \
  AUTHELIA_STORAGE_ENCRYPTION_KEY \
  AUTHELIA_REDIS_PASSWORD \
  AUTHELIA_SMTP_PASSWORD \
  AUTHELIA_OIDC_HMAC_SECRET \
  AUTHELIA_OIDC_CLIENT_NPM_SECRET \
  AUTHELIA_OIDC_CLIENT_NOCODB_SECRET \
  AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET \
  AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET \
  AUTHELIA_OIDC_CLIENT_DAGU_SECRET \
  AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET \
  AUTHELIA_OIDC_CLIENT_MONITORING_SECRET \
  AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET \
  AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET \
  AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET \
  AUTHELIA_OIDC_CLIENT_CLI_SECRET; do
  eval "val=\$$var"
  printf '%s' "$val" > "/tmp/.secrets.d/$var"
done

echo "[init] Generating users database..."

# Users database (heredoc safe for $ in Argon2 hashes)
cat > /tmp/users_database.yml <<USERDB
---
users:
  me@diegonmarcos.com:
    displayname: "Diego"
    password: "$AUTHELIA_USER_DIEGO_HASH"
    email: me@diegonmarcos.com
    groups:
      - admins
      - users
USERDB

# JWKS key: generate a YAML overlay with the PEM properly indented
# Authelia merges multiple --config files; this avoids template multiline issues
echo "[init] Generating JWKS overlay..."
cat > /tmp/jwks-overlay.yml <<'JWKSEOF'
identity_providers:
  oidc:
    jwks:
      - key_id: main
        algorithm: RS256
        use: sig
        key: |
JWKSEOF
sed 's/^/              /' /config/oidc_jwks.pem >> /tmp/jwks-overlay.yml

echo "[init] Starting Authelia..."
exec authelia \
  --config /config/configuration.yml \
  --config /tmp/jwks-overlay.yml \
  --config.experimental.filters template
