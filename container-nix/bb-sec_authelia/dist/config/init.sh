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
  -e "s|\${AUTHELIA_SMTP_PASSWORD}|$AUTHELIA_SMTP_PASSWORD|g" \
  /config/configuration.yml.tpl > /config/configuration.yml

sed \
  -e "s|\${AUTHELIA_USER_DIEGO_HASH}|$AUTHELIA_USER_DIEGO_HASH|g" \
  /config/users_database.yml.tpl > /config/users_database.yml

# Inject JWKS private key into configuration
if [ -f /config/oidc_jwks.pem ]; then
  echo "[init] Injecting OIDC JWKS key into configuration..."
  awk '
    /key: __JWKS_KEY__/ {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      print ind "key: |"
      while ((getline line < "/config/oidc_jwks.pem") > 0)
        print ind "  " line
      next
    }
    { print }
  ' /config/configuration.yml > /config/configuration.yml.tmp
  mv /config/configuration.yml.tmp /config/configuration.yml
fi

echo "[init] Starting Authelia..."
exec authelia --config /config/configuration.yml
