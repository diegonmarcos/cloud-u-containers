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
  AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET \
  AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET \
  AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET \
  AUTHELIA_OIDC_CLIENT_DAGU_SECRET \
  AUTHELIA_OIDC_CLIENT_MONITORING_SECRET \
  AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET \
  AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET \
  AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET \
  AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET \
  AUTHELIA_OIDC_CLIENT_NPM_SECRET \
  AUTHELIA_OIDC_CLIENT_NOCODB_SECRET \
  AUTHELIA_SMTP_PASSWORD

cp /config/users_database.yml.tpl /config/users_database.yml
subst /config/users_database.yml AUTHELIA_USER_DIEGO_HASH

# Inject JWKS private key into configuration (POSIX shell — works on BusyBox Alpine)
if [ -f /config/oidc_jwks.pem ]; then
  echo "[init] Injecting OIDC JWKS key into configuration..."
  LINE=$(grep -n '__JWKS_KEY__' /config/configuration.yml | head -1 | cut -d: -f1)
  if [ -n "$LINE" ]; then
    IND=$(sed -n "${LINE}p" /config/configuration.yml | sed 's/key:.*//')
    {
      head -n $((LINE - 1)) /config/configuration.yml
      printf '%skey: |\n' "$IND"
      while IFS= read -r pem_line; do
        printf '%s  %s\n' "$IND" "$pem_line"
      done < /config/oidc_jwks.pem
      tail -n +$((LINE + 1)) /config/configuration.yml
    } > /config/configuration.yml.tmp
    mv /config/configuration.yml.tmp /config/configuration.yml
    echo "[init] JWKS key injected successfully"
  else
    echo "[init] WARNING: __JWKS_KEY__ placeholder not found"
  fi
else
  echo "[init] WARNING: /config/oidc_jwks.pem not found — OIDC will not work"
fi

echo "[init] Starting Authelia..."
exec authelia --config /config/configuration.yml
