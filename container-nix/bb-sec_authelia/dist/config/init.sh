#!/bin/sh
set -e

echo "[init] Substituting secrets into configuration..."
sed \
  -e "s|\${AUTHELIA_JWT_SECRET}|$AUTHELIA_JWT_SECRET|g" \
  -e "s|\${AUTHELIA_SESSION_SECRET}|$AUTHELIA_SESSION_SECRET|g" \
  -e "s|\${AUTHELIA_STORAGE_ENCRYPTION_KEY}|$AUTHELIA_STORAGE_ENCRYPTION_KEY|g" \
  -e "s|\${AUTHELIA_REDIS_PASSWORD}|$AUTHELIA_REDIS_PASSWORD|g" \
  -e "s|\${AUTHELIA_OIDC_HMAC_SECRET}|$AUTHELIA_OIDC_HMAC_SECRET|g" \
  -e "s|\${AUTHELIA_OIDC_CLIENT_CLI_SECRET}|$AUTHELIA_OIDC_CLIENT_CLI_SECRET|g" \
  -e "s|\${AUTHELIA_OIDC_CLIENT_NPM_SECRET}|$AUTHELIA_OIDC_CLIENT_NPM_SECRET|g" \
  -e "s|\${AUTHELIA_OIDC_CLIENT_NOCODB_SECRET}|$AUTHELIA_OIDC_CLIENT_NOCODB_SECRET|g" \
  /config/configuration.yml.tpl > /config/configuration.yml

sed \
  -e "s|\${AUTHELIA_USER_DIEGO_HASH}|$AUTHELIA_USER_DIEGO_HASH|g" \
  /config/users_database.yml.tpl > /config/users_database.yml

# Write OIDC JWKS key file if env var is set
if [ -n "$AUTHELIA_OIDC_JWKS_KEY" ]; then
  echo "[init] Writing OIDC JWKS key..."
  printf '%s\n' "$AUTHELIA_OIDC_JWKS_KEY" > /config/oidc_jwks.pem
  chmod 600 /config/oidc_jwks.pem
fi

echo "[init] Starting Authelia..."
exec authelia --config /config/configuration.yml
