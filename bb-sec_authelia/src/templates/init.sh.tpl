#!/bin/sh
# Authelia init — minimal, declarative, no secret-shell-mangling.
#
# The engine produces dist/.secrets.d/<KEY> (mode 0600) and auto-mounts it
# at /run/secrets/ via _shared/engine.nix. The {{ secret "/run/secrets/X" }}
# template directive in configuration.yml reads each value at startup.
# No eval/printf/sed loop needed — every secret is already a file in the
# container at the canonical path before authelia starts.
#
# Two artefacts still need rendering at boot (multi-line, env-derived):
#   /tmp/users_database.yml    — user list with hashed password from $env
#   /tmp/jwks-overlay.yml      — wraps the PEM private key from /run/secrets/
set -e

echo "[init] Generating users database..."
cat > /tmp/users_database.yml <<USERDB
---
users:
  me@@BASE_DOMAIN@:
    displayname: "Diego"
    password: "$AUTHELIA_USER_DIEGO_HASH"
    email: me@@BASE_DOMAIN@
    groups:
      - admins
      - users
USERDB

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
# Indent each line of the PEM by 14 spaces so it nests under `key: |`.
# Source: /run/secrets/AUTHELIA_OIDC_JWKS_PRIVATE_KEY (engine-mounted, mode 0600).
awk '{ print "              " $0 }' /run/secrets/AUTHELIA_OIDC_JWKS_PRIVATE_KEY >> /tmp/jwks-overlay.yml

echo "[init] Starting Authelia..."
exec authelia \
  --config /config/configuration.yml \
  --config /tmp/jwks-overlay.yml \
  --config.experimental.filters template
