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
SIEVE_FILE="/opt/containers/stalwart/configs/default.sieve"

PW=$(cat "$SECRETS_DIR/ADMIN_PASSWORD" 2>/dev/null || echo)
[ -z "$PW" ] && echo "[activate] No ADMIN_PASSWORD found, skipping" && exit 0

echo "[activate] Waiting for Stalwart admin API on $BASE ..."
_ready=0
for i in $(seq 1 60); do
  _code=$(curl -sk -o /dev/null -w '%{http_code}' -u "admin:$PW" "$BASE/jmap/session" 2>/dev/null || echo 000)
  case "$_code" in
    2*|4*) _ready=1; break ;;
  esac
  sleep 2
done
if [ "$_ready" != 1 ]; then
  echo "[activate] ERROR: Stalwart admin API never became ready (last HTTP $_code)" >&2
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

echo "[activate] Done — folders + sieve ensured"
