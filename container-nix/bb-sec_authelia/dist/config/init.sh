#!/bin/sh
set -e

CONFIG_VARS='$AUTHELIA_JWT_SECRET $AUTHELIA_SESSION_SECRET $AUTHELIA_STORAGE_ENCRYPTION_KEY $AUTHELIA_REDIS_PASSWORD $AUTHELIA_OIDC_HMAC_SECRET $AUTHELIA_OIDC_CLIENT_CLI_SECRET $AUTHELIA_OIDC_CLIENT_NPM_SECRET $AUTHELIA_OIDC_CLIENT_NOCODB_SECRET'
USER_VARS='$AUTHELIA_USER_DIEGO_HASH'

echo "[init] Substituting secrets into configuration..."
envsubst "$CONFIG_VARS" < /config/configuration.yml.tpl > /config/configuration.yml
envsubst "$USER_VARS" < /config/users_database.yml.tpl > /config/users_database.yml

# Write OIDC JWKS key file if env var is set
if [ -n "$AUTHELIA_OIDC_JWKS_KEY" ]; then
  echo "[init] Writing OIDC JWKS key..."
  printf '%s\n' "$AUTHELIA_OIDC_JWKS_KEY" > /config/oidc_jwks.pem
  chmod 600 /config/oidc_jwks.pem
fi

echo "[init] Starting Authelia..."
exec authelia --config /config/configuration.yml
