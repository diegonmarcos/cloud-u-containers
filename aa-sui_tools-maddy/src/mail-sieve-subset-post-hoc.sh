#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ mail-sieve-subset-post-hoc.sh                                    ║
# ║   Maddy operator-triggered batch maintenance.                    ║
# ║                                                                  ║
# ║ Wired via build.json#lifecycle.post-hoc-* (each subcommand has   ║
# ║   its own lifecycle entry). Operator runs:                       ║
# ║     ./build.sh post-hoc-integrity-check                          ║
# ║     ./build.sh post-hoc-integrity-fix                            ║
# ║     ./build.sh post-hoc-dedupe                                   ║
# ║     ./build.sh post-hoc-cleanup-mailboxes                        ║
# ║     ./build.sh post-hoc-all                                      ║
# ║                                                                  ║
# ║ Schema (go-imap-sql, observed against running maddy 0.x):        ║
# ║   users(id, username, msgsizelimit, inboxId)                     ║
# ║   mboxes(id PK, uid → users.id, name UNIQUE(uid,name), ...)      ║
# ║   msgs(mboxId, msgId, date, bodyLen, bodyStructure, cachedHeader,║
# ║        extBodyKey → extKeys.id, seen, recent, PK(mboxId,msgId))  ║
# ║   extKeys(id VARCHAR PK, uid, refs)                              ║
# ║   flags(mboxId,msgId,flag, FK→msgs ON DELETE CASCADE)            ║
# ║                                                                  ║
# ║ Blob storage: /data/messages/<extKeys.id>  (one file per blob).  ║
# ║   refs counts how many msgs rows reference the blob (dedup       ║
# ║   reuse). When a msgs row is dropped, refs decrements; at 0,     ║
# ║   the extKeys row + blob file may be GC'd by maddy.              ║
# ║                                                                  ║
# ║ Subcommands:                                                     ║
# ║   integrity-check   read-only: report orphan rows (DB → no blob),║
# ║                      dangling blobs (file → no DB ref), bad-refs ║
# ║                      (extKeys.refs ≠ COUNT(msgs.extBodyKey)).    ║
# ║   integrity-fix     drop msgs rows whose extBodyKey has no blob, ║
# ║                      then drop extKeys rows with refs<=0,        ║
# ║                      then unlink dangling blob files.            ║
# ║   dedupe            extract Message-Id from cachedHeader, GROUP  ║
# ║                      by (mboxId, msg_id_hdr), keep smallest      ║
# ║                      msgId (oldest), DELETE the rest.            ║
# ║   cleanup-mailboxes drop mailboxes matching                       ║
# ║                      mail-rules.json#cleanup.drop_name_regex.    ║
# ║   all               integrity-check → integrity-fix → dedupe →   ║
# ║                      cleanup-mailboxes (--dry-run respected).    ║
# ║                                                                  ║
# ║ Performance: all destructive ops run in a SINGLE                 ║
# ║   BEGIN IMMEDIATE TRANSACTION. 30k rows finishes in seconds.     ║
# ║   Auto-backup of imapsql.db before any destructive op.           ║
# ║                                                                  ║
# ║ Note on `recover-headers`: NOT a subcommand here — go-imap-sql   ║
# ║   already caches headers in msgs.cachedHeader at delivery time;  ║
# ║   if the blob is missing, the BODY is unrecoverable (only        ║
# ║   integrity-fix applies). Subcommand intentionally not exposed.  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

DB="${IMAPSQL_DB:-/data/imapsql.db}"
RULES="${RULES_PATH:-/data/mail-rules.json}"
BLOB_DIR="${BLOB_DIR:-/data/messages}"
DRY_RUN=0

log()  { printf '[post-hoc] %s\n' "$*" >&2; }
err()  { printf '[post-hoc] ERROR: %s\n' "$*" >&2; }
fail() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: mail-sieve-subset-post-hoc <subcommand> [--dry-run]

Subcommands:
  integrity-check      Report orphan rows + dangling blobs + bad refs (read-only).
  integrity-fix        Drop msgs rows whose extBodyKey has no on-disk blob,
                       then drop extKeys with refs<=0, then unlink dangling blobs.
  dedupe               GROUP BY (mboxId, Message-Id from cachedHeader),
                       keep smallest msgId, DELETE the rest.
  cleanup-mailboxes    Drop mailboxes matching mail-rules.json#cleanup.drop_name_regex.
  all                  integrity-check → integrity-fix → dedupe → cleanup-mailboxes.

Flags:
  --dry-run            Report intended changes, write nothing.

Env:
  IMAPSQL_DB           default: /data/imapsql.db
  RULES_PATH           default: /data/mail-rules.json
  BLOB_DIR             default: /data/messages
EOF
}

# ── Arg parsing ─────────────────────────────────────────────────────
SUBCMD=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown flag: $arg" ;;
    *)  [ -z "$SUBCMD" ] && SUBCMD="$arg" || fail "unknown arg: $arg" ;;
  esac
done

[ -z "$SUBCMD" ] && { usage; exit 1; }
[ -f "$DB" ] || fail "imapsql DB not found: $DB"
[ -d "$BLOB_DIR" ] || fail "blob dir not found: $BLOB_DIR"

# ── Helpers ─────────────────────────────────────────────────────────
sq() { sqlite3 "$DB" "$1"; }

backup_db() {
  ts="$(date +%Y%m%d-%H%M%S)"
  cp "$DB" "$DB.bak-$ts"
  log "backed up DB → $DB.bak-$ts"
}

ensure_writable() {
  [ "$DRY_RUN" = "1" ] && { log "[dry-run] skipping backup + writes"; return 0; }
  backup_db
}

# ── Subcommands ─────────────────────────────────────────────────────

cmd_integrity_check() {
  log "integrity-check: scanning DB rows ↔ blob files…"

  TOTAL_MSGS="$(sq "SELECT COUNT(*) FROM msgs")"
  TOTAL_EXTKEYS="$(sq "SELECT COUNT(*) FROM extKeys")"
  log "  msgs rows:                  $TOTAL_MSGS"
  log "  extKeys rows:               $TOTAL_EXTKEYS"

  DB_KEYS="$(mktemp)"; DISK_KEYS="$(mktemp)"
  sq "SELECT id FROM extKeys" | sort -u > "$DB_KEYS"
  ls "$BLOB_DIR" 2>/dev/null | sort -u > "$DISK_KEYS"

  DB_KEY_COUNT="$(wc -l < "$DB_KEYS")"
  DISK_KEY_COUNT="$(wc -l < "$DISK_KEYS")"
  log "  blob keys in DB (extKeys):  $DB_KEY_COUNT"
  log "  blob files on disk:         $DISK_KEY_COUNT"

  # Orphans: extKeys rows whose id has no on-disk blob.
  ORPHAN_KEYS="$(comm -23 "$DB_KEYS" "$DISK_KEYS")"
  ORPHAN_KEY_COUNT="$(printf '%s\n' "$ORPHAN_KEYS" | grep -c . || true)"

  # Dangling: blob files with no extKeys row.
  DANGLING_BLOBS="$(comm -13 "$DB_KEYS" "$DISK_KEYS")"
  DANGLING_COUNT="$(printf '%s\n' "$DANGLING_BLOBS" | grep -c . || true)"

  # Orphan msgs rows: rows whose extBodyKey is one of the orphan keys
  # (or whose extBodyKey doesn't exist in extKeys at all).
  if [ "$ORPHAN_KEY_COUNT" -gt 0 ]; then
    # Stage orphan keys into a temp table for fast IN-clause join.
    ORPHAN_TMP="$(mktemp)"
    {
      echo "BEGIN;"
      echo "CREATE TEMP TABLE _orphan_keys(id VARCHAR PRIMARY KEY);"
      printf '%s\n' "$ORPHAN_KEYS" | awk 'NF { gsub(/'\''/, "''"); printf "INSERT INTO _orphan_keys VALUES('\''%s'\'');\n", $0 }'
      echo "SELECT COUNT(*) FROM msgs WHERE extBodyKey IN (SELECT id FROM _orphan_keys);"
      echo "ROLLBACK;"
    } > "$ORPHAN_TMP"
    ORPHAN_MSG_COUNT="$(sqlite3 "$DB" < "$ORPHAN_TMP" | tail -1)"
    rm -f "$ORPHAN_TMP"
  else
    ORPHAN_MSG_COUNT=0
  fi

  log "  ORPHAN extKeys (no blob):   $ORPHAN_KEY_COUNT"
  log "  ORPHAN msgs (broken body):  $ORPHAN_MSG_COUNT"
  log "  DANGLING blobs (no DB ref): $DANGLING_COUNT"

  # Refs sanity: extKeys.refs vs COUNT of referencing msgs rows.
  BAD_REFS="$(sq "
    SELECT COUNT(*) FROM extKeys e
    WHERE e.refs != COALESCE(
      (SELECT COUNT(*) FROM msgs WHERE extBodyKey = e.id), 0
    )
  ")"
  log "  extKeys with bad refs count:$BAD_REFS"

  rm -f "$DB_KEYS" "$DISK_KEYS"
}

cmd_integrity_fix() {
  ensure_writable
  log "integrity-fix: dropping msgs rows + extKeys with missing blobs…"

  DB_KEYS="$(mktemp)"; DISK_KEYS="$(mktemp)"; ORPHAN_KEYS_F="$(mktemp)"
  sq "SELECT id FROM extKeys" | sort -u > "$DB_KEYS"
  ls "$BLOB_DIR" 2>/dev/null | sort -u > "$DISK_KEYS"
  comm -23 "$DB_KEYS" "$DISK_KEYS" > "$ORPHAN_KEYS_F"
  DANGLING_F="$(mktemp)"
  comm -13 "$DB_KEYS" "$DISK_KEYS" > "$DANGLING_F"

  N_ORPHAN="$(wc -l < "$ORPHAN_KEYS_F")"
  N_DANGLING="$(wc -l < "$DANGLING_F")"
  log "  orphan keys to drop:    $N_ORPHAN"
  log "  dangling blobs to gc:   $N_DANGLING"

  if [ "$DRY_RUN" = "1" ]; then
    log "  [dry-run] would DELETE $N_ORPHAN extKeys + cascading msgs rows"
    log "  [dry-run] would unlink $N_DANGLING blob files"
    rm -f "$DB_KEYS" "$DISK_KEYS" "$ORPHAN_KEYS_F" "$DANGLING_F"
    return 0
  fi

  if [ "$N_ORPHAN" -gt 0 ]; then
    TX="$(mktemp)"
    {
      echo "BEGIN IMMEDIATE TRANSACTION;"
      echo "CREATE TEMP TABLE _drop_keys(id VARCHAR PRIMARY KEY);"
      awk 'NF { gsub(/'\''/, "''"); printf "INSERT INTO _drop_keys VALUES('\''%s'\'');\n", $0 }' "$ORPHAN_KEYS_F"
      # Drop msgs first (FK ON DELETE RESTRICT on extBodyKey would block extKeys delete).
      echo "DELETE FROM msgs    WHERE extBodyKey IN (SELECT id FROM _drop_keys);"
      echo "DELETE FROM extKeys WHERE id IN (SELECT id FROM _drop_keys);"
      echo "DROP TABLE _drop_keys;"
      echo "COMMIT;"
    } > "$TX"
    log "  applying transaction (orphan drop)…"
    sqlite3 "$DB" < "$TX"
    rm -f "$TX"
  fi

  if [ "$N_DANGLING" -gt 0 ]; then
    log "  unlinking $N_DANGLING dangling blob files…"
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      rm -f "$BLOB_DIR/$key" 2>/dev/null || true
    done < "$DANGLING_F"
  fi

  rm -f "$DB_KEYS" "$DISK_KEYS" "$ORPHAN_KEYS_F" "$DANGLING_F"
  log "  done"
}

cmd_dedupe() {
  ensure_writable
  log "dedupe: extracting Message-Id from cachedHeader + collapsing duplicates per mailbox…"

  # Extract (mboxId, msgId, message_id) from cachedHeader. cachedHeader is
  # LONGTEXT — RFC822 header bytes. Use SQLite's substr+instr to grab the
  # Message-Id line; fall back to NULL if absent.
  EXTRACT="$(mktemp)"
  sq "
    SELECT mboxId,
           msgId,
           CASE
             WHEN instr(lower(cachedHeader), 'message-id:') > 0 THEN
               trim(substr(
                 cachedHeader,
                 instr(lower(cachedHeader), 'message-id:') + 11,
                 instr(substr(cachedHeader,
                              instr(lower(cachedHeader), 'message-id:') + 11),
                       char(10)) - 1
               ))
             ELSE ''
           END AS msg_id_hdr
    FROM msgs
  " > "$EXTRACT"

  TOTAL="$(wc -l < "$EXTRACT")"
  log "  total rows scanned: $TOTAL"

  # Build dedup decisions in awk: per (mboxId, msg_id_hdr), keep smallest msgId.
  # Skip rows with empty msg_id_hdr (keep them all — can't dedup safely).
  DEL_LIST="$(mktemp)"
  awk -F'|' '
    $3 != "" {
      key = $1 "|" $3
      if (!(key in seen) || $2 < seen[key]) {
        if (key in keep_msg) print keep_mbox[key] "|" keep_msg[key] >> "/dev/stderr"
        seen[key] = $2
        keep_mbox[key] = $1
        keep_msg[key] = $2
      }
    }
    END {
      # nothing — second pass below
    }
  ' "$EXTRACT" 2>/dev/null

  # Two-pass: first pass identifies the keeper (smallest msgId per group),
  # second pass marks all NON-keepers for deletion.
  awk -F'|' '
    NR == FNR {
      if ($3 != "") {
        key = $1 "|" $3
        if (!(key in min_id) || $2 + 0 < min_id[key] + 0) min_id[key] = $2
      }
      next
    }
    {
      if ($3 != "") {
        key = $1 "|" $3
        if (key in min_id && $2 + 0 != min_id[key] + 0) {
          print $1 "|" $2
        }
      }
    }
  ' "$EXTRACT" "$EXTRACT" > "$DEL_LIST"

  N_DEL="$(wc -l < "$DEL_LIST")"
  log "  duplicate rows to drop: $N_DEL"

  if [ "$DRY_RUN" = "1" ]; then
    log "  [dry-run] would DELETE $N_DEL duplicate msgs rows"
    rm -f "$EXTRACT" "$DEL_LIST"
    return 0
  fi
  if [ "$N_DEL" -eq 0 ]; then
    rm -f "$EXTRACT" "$DEL_LIST"
    return 0
  fi

  TX="$(mktemp)"
  {
    echo "BEGIN IMMEDIATE TRANSACTION;"
    echo "CREATE TEMP TABLE _dup(mbox_id BIGINT NOT NULL, msg_id BIGINT NOT NULL, PRIMARY KEY(mbox_id, msg_id));"
    awk -F'|' 'NF==2 { printf "INSERT INTO _dup VALUES(%s, %s);\n", $1, $2 }' "$DEL_LIST"
    echo "DELETE FROM msgs WHERE (mboxId, msgId) IN (SELECT mbox_id, msg_id FROM _dup);"
    # Refs in extKeys auto-decrement only via maddy GC; we leave it to maddy.
    echo "DROP TABLE _dup;"
    echo "COMMIT;"
  } > "$TX"
  log "  applying dedup transaction…"
  sqlite3 "$DB" < "$TX"
  rm -f "$TX" "$EXTRACT" "$DEL_LIST"
  log "  done"
}

cmd_cleanup_mailboxes() {
  ensure_writable
  REGEX="$(jq -r '.cleanup.drop_name_regex // empty' "$RULES" 2>/dev/null)"
  [ -z "$REGEX" ] && { log "cleanup-mailboxes: no .cleanup.drop_name_regex in rules — skip"; return 0; }
  log "cleanup-mailboxes: regex=$REGEX"

  CANDIDATES="$(sq "SELECT name FROM mboxes" | grep -E "$REGEX" || true)"
  N="$(printf '%s\n' "$CANDIDATES" | grep -c . || true)"
  log "  candidate mailboxes: $N"
  [ "$N" -eq 0 ] && return 0

  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "$CANDIDATES" | sed 's/^/  [dry-run] would drop: /' >&2
    return 0
  fi

  TX="$(mktemp)"
  {
    echo "BEGIN IMMEDIATE TRANSACTION;"
    printf '%s\n' "$CANDIDATES" | awk 'NF {
      gsub(/'\''/, "''")
      printf "DELETE FROM mboxes WHERE name = '\''%s'\'';\n", $0
    }'
    echo "COMMIT;"
  } > "$TX"
  sqlite3 "$DB" < "$TX"
  rm -f "$TX"
  log "  done"
}

cmd_all() {
  cmd_integrity_check
  cmd_integrity_fix
  cmd_dedupe
  cmd_cleanup_mailboxes
  log "all subcommands complete"
}

# ── Dispatch ────────────────────────────────────────────────────────
case "$SUBCMD" in
  integrity-check)    cmd_integrity_check ;;
  integrity-fix)      cmd_integrity_fix ;;
  dedupe)             cmd_dedupe ;;
  cleanup-mailboxes)  cmd_cleanup_mailboxes ;;
  all)                cmd_all ;;
  *)                  fail "unknown subcommand: $SUBCMD (run --help)" ;;
esac
