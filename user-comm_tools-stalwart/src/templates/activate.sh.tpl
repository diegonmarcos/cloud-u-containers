#!/bin/sh
# ── Stalwart v0.16 activation hook ─────────────────────────────────────
# Runs after compose-up. Idempotent.
#
# Per user in build.json#users:
#   1. Wait for admin API.
#   2. Discover JMAP accountId from /jmap/session.
#   3. Create mailbox hierarchy (4 parents + 10 leaves) declared in
#      mail-rules-general.json::folders + folders_ui. Skips existing.
#   4. Upload + activate dist/configs/default.sieve via JMAP Sieve API.
#
# Plus (admin scope):
#   D. Apply outbound MTA routes declared in build.json#mta_routes,
#      emitted as configs/mta-routes.json by the flake. Secrets pulled
#      from $SECRETS_DIR/<env-var-name>. No hardcoded data in this file.
#
# Domain + Account creation are owned by stalwart-cli apply (manual
# recovery-mode bootstrap), NOT this hook.
#
# Folder list and user/pass-env pairs are injected by the flake from
# mail-rules-general.json + build.json#users. They appear below inside
# single-quoted strings; NEVER reference the @VAR@ tokens in comments
# (engine substitutes everywhere — multi-line values break shell parsing).
set -e
BASE="https://@BIND_IP@:@APP_PORT@"
SECRETS_DIR="/opt/containers/stalwart/.secrets.d"
CONFIGS_DIR="/opt/containers/stalwart/configs"
SIEVE_FILE="$CONFIGS_DIR/default.sieve"
MTA_ROUTES_FILE="$CONFIGS_DIR/mta-routes.json"
APPLY_ROUTES_PY="$CONFIGS_DIR/apply-mta-routes.py"
APPLY_CERT_PY="$CONFIGS_DIR/apply-tls-cert.py"
TLS_DIR="/opt/containers/maddy/tls"

# Admin identity sourced from build.json#users.admin (data-driven). The
# pre-v0.16 "admin:$ADMIN_PASSWORD" magic principal only exists in
# recovery_mode; post-bootstrap, JMAP requires a real principal — the
# user with role=admin (mkUserLines in flake.nix gates this on key=="admin").
ADMIN_EMAIL="@ADMIN_EMAIL@"
ADMIN_PW=$(cat "$SECRETS_DIR/@ADMIN_PASS_ENV@" 2>/dev/null || echo)
[ -z "$ADMIN_PW" ] && echo "[activate] No @ADMIN_PASS_ENV@ found, skipping" && exit 0

# Keep legacy $PW for any reader that still expects it (per-user sieve loop
# below uses its own $USER_PW, so this is only documentary).
PW="$ADMIN_PW"

echo "[activate] Waiting for Stalwart JMAP on $BASE (probe: $ADMIN_EMAIL) ..."
_ready=0
for i in $(seq 1 60); do
  _code=$(curl -sk -o /dev/null -w '%{http_code}' -u "$ADMIN_EMAIL:$ADMIN_PW" "$BASE/jmap/session" 2>/dev/null || echo 000)
  case "$_code" in
    2*) _ready=1; break ;;
    4*) echo "[activate] WARN: $ADMIN_EMAIL auth returned $_code — Stalwart up but admin principal not yet bootstrapped?" >&2
        _ready=2; break ;;
  esac
  sleep 2
done
if [ "$_ready" = 0 ]; then
  echo "[activate] ERROR: Stalwart JMAP never became ready (last HTTP $_code)" >&2
  exit 1
fi

# Resolve a mailbox id by name from current Mailbox/get response (JSON in $1).
# Outputs the id (no quotes) or empty string.
mailbox_id_for() {
  printf '%s' "$1" | python3 -c "
import sys, json, re
data = sys.stdin.read()
name = '''$2'''
# Find the most-recent Mailbox/get 'list' array.
m = re.search(r'\"list\":\\s*(\\[.*?\\])\\s*,\\s*\"notFound\"', data, re.DOTALL)
if not m:
    sys.exit()
try:
    for box in json.loads(m.group(1)):
        if box.get('name') == name:
            print(box['id'])
            break
except Exception:
    pass
"
}

# ── Per-user setup ────────────────────────────────────────────────────
for PAIR in @USERS_LIST@; do
  U=${PAIR%%=*}
  PASS_ENV=${PAIR#*=}
  USER="$U@@BASE_DOMAIN@"
  USER_PW=$(cat "$SECRETS_DIR/$PASS_ENV" 2>/dev/null || echo)
  if [ -z "$USER_PW" ]; then
    echo "[activate]   $USER: no password ($PASS_ENV), skipping"
    continue
  fi

  echo "[activate] Setup $USER..."

  SESSION=$(curl -sk -u "$USER:$USER_PW" "$BASE/jmap/session" 2>/dev/null)
  ACCOUNT_ID=$(printf '%s' "$SESSION" | grep -o '"urn:ietf:params:jmap:mail":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$ACCOUNT_ID" ]; then
    echo "[activate]   $USER: could not discover accountId, skipping"
    continue
  fi

  # ── Step B: create missing mailboxes ─────────────────────────────
  refresh_existing() {
    EXISTING=$(curl -sk -u "$USER:$USER_PW" -X POST "$BASE/jmap/" \
      -H "Content-Type: application/json" \
      -d "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Mailbox/get\",{\"accountId\":\"$ACCOUNT_ID\",\"ids\":null,\"properties\":[\"id\",\"name\",\"parentId\"]},\"0\"]]}" 2>/dev/null)
  }
  refresh_existing

  printf '%s\n' '@FOLDERS_LINES@' | while IFS='|' read -r FNAME FPARENT; do
    [ -z "$FNAME" ] && continue

    # Skip if already exists.
    EXISTING_ID=$(mailbox_id_for "$EXISTING" "$FNAME")
    if [ -n "$EXISTING_ID" ]; then
      continue
    fi

    # Resolve parentId (null for top-level, otherwise lookup parent's id).
    PARENT_JSON="null"
    if [ -n "$FPARENT" ]; then
      PARENT_ID=$(mailbox_id_for "$EXISTING" "$FPARENT")
      if [ -z "$PARENT_ID" ]; then
        echo "[activate]   skip '$FNAME' — parent '$FPARENT' not yet created"
        continue
      fi
      PARENT_JSON="\"$PARENT_ID\""
    fi

    RESP=$(curl -sk -u "$USER:$USER_PW" -X POST "$BASE/jmap/" \
      -H "Content-Type: application/json" \
      -d "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"],\"methodCalls\":[[\"Mailbox/set\",{\"accountId\":\"$ACCOUNT_ID\",\"create\":{\"new\":{\"name\":\"$FNAME\",\"parentId\":$PARENT_JSON}}},\"0\"]]}" 2>/dev/null)

    if printf '%s' "$RESP" | grep -q '"created":{[^}]*"id"'; then
      echo "[activate]   created mailbox '$FNAME'"
      refresh_existing
    else
      echo "[activate]   FAIL create '$FNAME': $(printf '%s' "$RESP" | head -c 200)"
    fi
  done

  # ── Step C: upload + activate sieve script ─────────────────────────
  if [ ! -f "$SIEVE_FILE" ]; then
    echo "[activate]   no $SIEVE_FILE, sieve skipped"
    continue
  fi

  SIEVE_ACCT=$(printf '%s' "$SESSION" | grep -o '"urn:ietf:params:jmap:sieve":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -z "$SIEVE_ACCT" ] && SIEVE_ACCT="$ACCOUNT_ID"

  UPLOAD_RESP=$(curl -sk -u "$USER:$USER_PW" -X POST "$BASE/jmap/upload/$SIEVE_ACCT/" \
    -H "Content-Type: application/sieve" --data-binary @"$SIEVE_FILE" 2>/dev/null)
  BLOB_ID=$(printf '%s' "$UPLOAD_RESP" | grep -o '"blobId":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$BLOB_ID" ]; then
    echo "[activate]   sieve blob upload failed: $UPLOAD_RESP"
    continue
  fi

  JMAP_RESP=$(curl -sk -u "$USER:$USER_PW" -X POST "$BASE/jmap/" \
    -H "Content-Type: application/json" \
    -d "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:sieve\"],\"methodCalls\":[[\"SieveScript/set\",{\"accountId\":\"$SIEVE_ACCT\",\"create\":{\"default\":{\"name\":\"default\",\"blobId\":\"$BLOB_ID\"}},\"onSuccessActivateScript\":\"#default\"},\"0\"]]}" 2>/dev/null)

  if printf '%s' "$JMAP_RESP" | grep -q '"created":{[^}]*"id"'; then
    echo "[activate]   sieve created + activated for $USER"
  else
    LIST=$(curl -sk -u "$USER:$USER_PW" -X POST "$BASE/jmap/" \
      -H "Content-Type: application/json" \
      -d "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:sieve\"],\"methodCalls\":[[\"SieveScript/get\",{\"accountId\":\"$SIEVE_ACCT\"},\"0\"]]}" 2>/dev/null)
    SID=$(printf '%s' "$LIST" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "$SID" ]; then
      curl -sk -u "$USER:$USER_PW" -X POST "$BASE/jmap/" \
        -H "Content-Type: application/json" \
        -d "{\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:sieve\"],\"methodCalls\":[[\"SieveScript/set\",{\"accountId\":\"$SIEVE_ACCT\",\"update\":{\"$SID\":{\"blobId\":\"$BLOB_ID\"}},\"onSuccessActivateScript\":\"$SID\"},\"0\"]]}" >/dev/null 2>&1
      echo "[activate]   sieve updated + activated for $USER"
    else
      echo "[activate]   sieve create+update both failed: $JMAP_RESP"
    fi
  fi
done

# ── Step D: outbound MTA routes (admin scope) ──────────────────────────
# Orchestration only. All data + JMAP logic lives in:
#   $MTA_ROUTES_FILE   — data, emitted from build.json#mta_routes by flake
#   $APPLY_ROUTES_PY   — engine, applies the data via JMAP
# Empty file or empty array = no-op (handled by the python helper).
if [ -s "$MTA_ROUTES_FILE" ] && [ -x "$APPLY_ROUTES_PY" -o -f "$APPLY_ROUTES_PY" ]; then
  echo "[activate] Applying MTA routes from $MTA_ROUTES_FILE (admin: $ADMIN_EMAIL)..."
  if python3 "$APPLY_ROUTES_PY" "$MTA_ROUTES_FILE" "$BASE" "$ADMIN_EMAIL:$ADMIN_PW" "$SECRETS_DIR"; then
    :
  else
    echo "[activate]   apply-mta-routes.py exit $?"
  fi
fi

# ── Step E: TLS certificate (admin scope) ──────────────────────────────
# Upsert the LE wildcard cert as a JMAP Certificate object so Stalwart
# serves the real cert instead of the rcgen self-signed one. Idempotent.
if [ -f "$TLS_DIR/fullchain.pem" ] && [ -f "$TLS_DIR/privkey.pem" ]; then
  echo "[activate] Applying TLS certificate from $TLS_DIR..."
  if python3 "$APPLY_CERT_PY" "$BASE" "$ADMIN_EMAIL:$ADMIN_PW" \
       "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem"; then
    :
  else
    echo "[activate]   apply-tls-cert.py exited $? (non-fatal)"
  fi
else
  echo "[activate]   TLS cert not yet on disk ($TLS_DIR) — skipping"
fi

echo "[activate] Done — folders + sieve + mta routes + tls cert ensured"
