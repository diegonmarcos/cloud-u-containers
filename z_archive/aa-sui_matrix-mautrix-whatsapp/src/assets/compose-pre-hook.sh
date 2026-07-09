#!/bin/sh
# compose-pre-hook.sh — runs on the VM before `docker compose up`.
# Renders config.yaml + registration.yaml into ./data by injecting the
# appservice tokens from .secrets into the engine-rendered templates.
# Tokens live ONLY in sops -> dist/.secrets (gitignored); they are never
# written into the committed configs/ templates.
set -eu
DIR="$(dirname "$0")"     # <deploy>/assets
ROOT="$DIR/.."            # <deploy>
mkdir -p "$ROOT/data"

# Load AS_TOKEN / HS_TOKEN (KEY=VALUE dotenv from build.sh secrets).
set -a
. "$ROOT/.secrets"
set +a

# Literal injection of the two ${TOKEN} placeholders. Tokens are hex
# (openssl rand -hex) so gsub replacement is safe; no regex metachars.
inject() {
    awk -v as="$AS_TOKEN" -v hs="$HS_TOKEN" '
        { gsub(/\$\{AS_TOKEN\}/, as); gsub(/\$\{HS_TOKEN\}/, hs); print }
    ' "$1" > "$2"
}

# config.yaml: seed only if absent — mautrix auto-upgrades this file in place
# on startup, so we must not clobber the bridge-maintained version on redeploy.
[ -f "$ROOT/data/config.yaml" ] || inject "$ROOT/configs/config.yaml" "$ROOT/data/config.yaml"

# registration.yaml: refresh every deploy (idempotent — tokens are fixed).
inject "$ROOT/configs/registration.yaml" "$ROOT/data/registration.yaml"

exit 0
