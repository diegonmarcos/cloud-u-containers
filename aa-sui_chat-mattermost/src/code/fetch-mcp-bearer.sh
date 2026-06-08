#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ fetch-mcp-bearer.sh — pre_hook step                              ║
# ║                                                                  ║
# ║ Refreshes BEARER_TOKEN in .secrets via Authelia OIDC client-     ║
# ║ credentials grant on every compose-up. Token then substitutes    ║
# ║ into MM_PLUGINSETTINGS_PLUGINS_MATTERMOST_AI_MCPSERVERS at       ║
# ║ docker-compose parse time (engine runs `docker compose            ║
# ║ --env-file .secrets up -d`, compose-level interpolation reads    ║
# ║ from --env-file).                                                ║
# ║                                                                  ║
# ║ Authelia client: mattermost-cc                                   ║
# ║   grant: client_credentials                                       ║
# ║   scopes: authelia.bearer.authz                                  ║
# ║   audience: api., rss., mcp.diegonmarcos.com                     ║
# ║   declared in: bb-sec_authelia/src/oidc-clients.json             ║
# ║                                                                  ║
# ║ Failure modes (any of these → BEARER_TOKEN unchanged, MCPs 401   ║
# ║ until next deploy):                                              ║
# ║   - AUTHELIA_OIDC_MATTERMOST_SECRET missing from .secrets        ║
# ║   - Authelia unreachable                                          ║
# ║   - Client config rejects the request                            ║
# ║ Script never blocks deploy — auth failure is a soft fail.        ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

log() { printf '[fetch-mcp-bearer] %s\n' "$1"; }

SECRETS_FILE="$(dirname "$0")/../.secrets"
if [ ! -f "$SECRETS_FILE" ]; then
    log "no .secrets file at $SECRETS_FILE — skip (compose-up will run with stale token)"
    exit 0
fi

# Load client_id + client_secret from .secrets without affecting current env.
# `set +u` because .secrets may export many KEY=VALUE pairs and a missing one
# below should not trip set -u.
set +u
# shellcheck disable=SC1090
. "$SECRETS_FILE" 2>/dev/null || true
set -u

CLIENT_ID="mattermost-cc"
CLIENT_SECRET="${AUTHELIA_OIDC_MATTERMOST_SECRET:-}"
TOKEN_URL="${AUTHELIA_TOKEN_URL:-https://auth.diegonmarcos.com/api/oidc/token}"
AUDIENCE="${MCP_AUDIENCE:-https://mcp.diegonmarcos.com/}"

if [ -z "$CLIENT_SECRET" ]; then
    log "AUTHELIA_OIDC_MATTERMOST_SECRET not set in .secrets — skip"
    exit 0
fi

log "requesting client_credentials token from $TOKEN_URL (audience=$AUDIENCE)"
RESP=$(curl -sf -X POST "$TOKEN_URL" \
    -u "$CLIENT_ID:$CLIENT_SECRET" \
    -d "grant_type=client_credentials" \
    -d "scope=authelia.bearer.authz" \
    -d "audience=$AUDIENCE" 2>/dev/null || true)

# jq path: .access_token. Fallback to grep+sed in case jq absent on host.
ACCESS_TOKEN=""
if command -v jq >/dev/null 2>&1; then
    ACCESS_TOKEN=$(printf '%s' "$RESP" | jq -r '.access_token // empty' 2>/dev/null || true)
else
    ACCESS_TOKEN=$(printf '%s' "$RESP" | grep -oE '"access_token"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 | awk -F'"' '{print $4}')
fi

if [ -z "$ACCESS_TOKEN" ]; then
    log "OAuth dance returned no access_token (Authelia reachable? client config OK?)"
    log "response head: $(printf '%s' "$RESP" | head -c 240)"
    exit 0
fi

# Replace existing BEARER_TOKEN line in .secrets (or append). awk index() per
# repo convention — avoid sed.
NEW="BEARER_TOKEN=$ACCESS_TOKEN"
if grep -qE '^BEARER_TOKEN=' "$SECRETS_FILE"; then
    awk -v new="$NEW" '
        index($0, "BEARER_TOKEN=") == 1 { print new; next }
        { print }
    ' "$SECRETS_FILE" > "${SECRETS_FILE}.tmp"
    chmod --reference="$SECRETS_FILE" "${SECRETS_FILE}.tmp" 2>/dev/null || chmod 0600 "${SECRETS_FILE}.tmp"
    mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
else
    printf '%s\n' "$NEW" >> "$SECRETS_FILE"
fi

log "wrote fresh BEARER_TOKEN to $SECRETS_FILE (length=${#ACCESS_TOKEN})"
