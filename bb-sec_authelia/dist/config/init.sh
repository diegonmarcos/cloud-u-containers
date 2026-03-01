#!/bin/sh
set -e

# Replace ${VAR} placeholders with env values using awk (literal string, no regex)
# Usage: subst <file> VAR1 VAR2 ...
subst() {
  _file="$1"; shift
  for _var in "$@"; do
    eval _val="\$$_var"
    awk -v pat="\${${_var}}" -v rep="$_val" '{
      while (i = index($0, pat)) {
        $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
      }
      print
    }' "$_file" > "$_file.tmp"
    mv "$_file.tmp" "$_file"
  done
}

echo "[init] Substituting secrets into configuration..."
cp /config/configuration.yml.tpl /config/configuration.yml
subst /config/configuration.yml \
  AUTHELIA_JWT_SECRET \
  AUTHELIA_SESSION_SECRET \
  AUTHELIA_STORAGE_ENCRYPTION_KEY \
  AUTHELIA_REDIS_PASSWORD \
  AUTHELIA_OIDC_HMAC_SECRET \
  AUTHELIA_OIDC_CLIENT_CLI_SECRET \
  AUTHELIA_OIDC_CLIENT_NPM_SECRET \
  AUTHELIA_OIDC_CLIENT_NOCODB_SECRET \
  AUTHELIA_SMTP_PASSWORD

cp /config/users_database.yml.tpl /config/users_database.yml
subst /config/users_database.yml AUTHELIA_USER_DIEGO_HASH

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
