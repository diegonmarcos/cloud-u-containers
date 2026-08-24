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
# ║   apply-rules       walk INBOX (skipping rows tagged \$distributed);║
# ║                      pipe each cachedHeader through delivery-time║
# ║                      with MAIL_SIEVE_STRATEGY=split → recover    ║
# ║                      routing decision (folder + flags); SQL-     ║
# ║                      direct COPY (NOT move) into the matched     ║
# ║                      category folder with rule keywords + no     ║
# ║                      \\Seen; tag the INBOX original \\Seen+        ║
# ║                      \$distributed. Idempotent — Dagu-friendly.   ║
# ║   reseed-inbox-archive  one-shot: COPY every msg from non-system  ║
# ║                      mailboxes into INBOX as \\Seen + \$distributed║
# ║                      (Message-Id deduped). Backfills the         ║
# ║                      chronological archive after enabling the    ║
# ║                      unified-inbox model.                        ║
# ║   all               integrity-check → integrity-fix → dedupe →   ║
# ║                      cleanup-mailboxes (--dry-run respected).    ║
# ║                      apply-rules is intentionally NOT in `all` — ║
# ║                      it's a corrective action, not maintenance.  ║
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
PRUNE_FALLBACK="${PRUNE_FALLBACK:-0}"

log()  { printf '[post-hoc] %s\n' "$*" >&2; }
err()  { printf '[post-hoc] ERROR: %s\n' "$*" >&2; }
fail() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: mail-sieve-subset-post-hoc <subcommand> [--dry-run]

Subcommands:
  integrity-check        Report orphan rows + dangling blobs + bad refs (read-only).
  integrity-fix          Drop msgs rows whose extBodyKey has no on-disk blob,
                         then drop extKeys with refs<=0, then unlink dangling blobs.
  dedupe                 GROUP BY (mboxId, Message-Id from cachedHeader),
                         keep smallest msgId, DELETE the rest.
  cleanup-mailboxes      Drop mailboxes matching mail-rules.json#cleanup.drop_name_regex.
  apply-rules            Walk INBOX (skipping rows already tagged \$distributed);
                         pipe each cachedHeader through delivery-time in split
                         mode to recover the routing decision; SQL-direct COPY
                         (NOT MOVE) into the matched category folder with
                         rule-derived keyword flags but no \\Seen. INBOX
                         retains every original (marked \\Seen + \$distributed).
                         Idempotent per-target-mailbox copy (never duplicates
                         a body already filed in the target). Detects
                         mail-rules.json changes (state file next to \$DB) and
                         re-opens fallback-only messages for re-evaluation.
                         --prune-fallback (default OFF; also PRUNE_FALLBACK=1)
                         deletes the redundant fallback copy of a message
                         just filed into a real category folder this run.
  reseed-inbox-archive   One-shot history backfill: COPY every msg from non-
                         system folders (Sent/Drafts/Trash/Junk excluded) into
                         INBOX as \\Seen + \$distributed, deduped by Message-Id.
                         Idempotent — safe to re-run.
  all                    integrity-check → integrity-fix → dedupe → cleanup-mailboxes.
                         (apply-rules + reseed-inbox-archive NOT included —
                         they are corrective/one-shot, not maintenance.)

Flags:
  --dry-run            Report intended changes, write nothing.
  --prune-fallback     apply-rules only, default OFF: delete the redundant
                       fallback copy of a message just filed into a real
                       category folder this run.

Env:
  IMAPSQL_DB           default: /data/imapsql.db
  RULES_PATH           default: /data/mail-rules.json
  BLOB_DIR             default: /data/messages
  FILTER_BIN           default: /usr/local/bin/mail-sieve-subset-delivery-time
  PRUNE_FALLBACK       default: 0 — same as --prune-fallback
EOF
}

# ── Arg parsing ─────────────────────────────────────────────────────
SUBCMD=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --prune-fallback) PRUNE_FALLBACK=1 ;;
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

  # ── Refs counter fixup ─────────────────────────────────────────
  # extKeys.refs is supposed to equal COUNT(msgs.extBodyKey = e.id).
  # SQL-direct deletes here bypass maddy's normal refs-- code path,
  # so refs drifts. Recompute in one UPDATE — idempotent + cheap.
  log "  recomputing extKeys.refs counters…"
  sqlite3 "$DB" <<'SQL'
BEGIN IMMEDIATE TRANSACTION;
UPDATE extKeys
   SET refs = (SELECT COUNT(*) FROM msgs WHERE msgs.extBodyKey = extKeys.id);
COMMIT;
SQL

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

cmd_apply_rules() {
  # Apply the delivery-time rule engine to undistributed INBOX messages
  # and place an UNREAD COPY (not MOVE) into each matched category folder.
  # INBOX retains every original (marked \Seen + $distributed); category
  # folders host the unread working set. The model:
  #
  #   delivery-time → drops every msg into INBOX (+\Seen), per
  #                   "delivery_strategy: unified-inbox" in rules JSON.
  #   apply-rules    → walks INBOX, calls delivery-time with
  #                    MAIL_SIEVE_STRATEGY=split to recover the routing
  #                    decision (folder + flags), then SQL-direct COPIES
  #                    the row into the target mailbox with rule-derived
  #                    keyword flags but WITHOUT \Seen, and tags the
  #                    INBOX original with \Seen + $distributed.
  #
  # Idempotency: $distributed keyword on the INBOX row excludes already-
  # processed messages from the next scan. Safe to run on a Dagu cron.
  # In addition (Part 1 below), the per-target copy step itself is
  # idempotent: a row is never INSERTed into a target mailbox that
  # already holds a copy with the same extBodyKey (same body blob) —
  # this makes re-opening a message (Part 2) safe to repeat.
  #
  # SQL-direct (one BEGIN IMMEDIATE TRANSACTION per run) is the
  # established pattern in this script (cf. cleanup-mailboxes,
  # integrity-fix). maddy imap-msgs copy can't be used for the unread-
  # copy semantic because it preserves source flags and doesn't return
  # the new target UIDs — so post-copy flag manipulation would need a
  # second SQL pass anyway. One SQL pass is cleaner.
  #
  # Pipeline:
  #   1. Resolve INBOX_ID, USER_ID.
  #   2. Ruleset-change detection (Part 2): hash the semantic content of
  #      $RULES; compare to the last-applied hash in a state file next
  #      to $DB. If a PRIOR hash existed and differs, clear $distributed
  #      on INBOX rows that are fallback-only (filed only in the
  #      routing_default mailbox, nowhere else), so the scan below
  #      re-evaluates them against the new rules. First-ever run (no
  #      state file) never mass-clears — it just records the hash.
  #   3. Bail if no undistributed msgs.
  #   4. Per candidate row: convert cachedHeader JSON → RFC822 → pipe
  #      through delivery-time (MAIL_SIEVE_STRATEGY=split). Capture
  #      target folder + comma-separated flag list.
  #   5. Generate one SQL script per target mailbox. Idempotency (Part
  #      1): rows whose extBodyKey is already present in the target
  #      mailbox are NOT re-inserted — only the INBOX original is
  #      stamped \Seen + $distributed. Otherwise:
  #        INSERT INTO msgs (target row, fresh msgId from uidnext)
  #        UPDATE extKeys.refs += 1   (blob shared across copies)
  #        INSERT INTO flags (rule-derived keywords on copy, no \Seen)
  #        INSERT INTO flags (\Seen + $distributed on INBOX original)
  #        UPDATE msgs.seen=1 on INBOX original
  #        UPDATE mboxes (uidnext + msgsCount += N per target)
  #   6. Execute. Optionally (Part 3, --prune-fallback, default OFF)
  #      delete the now-redundant fallback copy of any message that was
  #      just filed into a real category folder this run.
  #   7. Resync msgsCount sanity (cleans up any drift). Record the new
  #      ruleset hash.
  #
  # Trade-off: per-message subprocess to delivery-time ≈ 30ms each.
  # 2k messages ≈ 60s. Acceptable for a Dagu run every 2 min.
  # Single-instance guard. The Dagu DAG's max_active_runs:1 only bounds the
  # DAG run, not this process: the step is
  # `ssh ubuntu@10.0.0.3 "docker exec maddy ..."`, so when Dagu gives up on
  # the ssh the container-side process keeps running and the next 2-min tick
  # starts another one. MEASURED 2026-08-24: 10 concurrent apply-rules
  # processes livelocked on SQLite's single-writer lock — no run ever reached
  # the STATE_FILE write below, so the ruleset-hash re-open repeated on every
  # tick and 822 re-opened messages were never distributed. mkdir is the
  # atomic primitive (busybox sh in this image has no flock).
  LOCK_DIR="$(dirname "$DB")/.apply-rules.lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
  else
    _lpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
    if [ "$_lpid" -gt 0 ] 2>/dev/null && kill -0 "$_lpid" 2>/dev/null; then
      log "apply-rules: run pid $_lpid still holds $LOCK_DIR — exiting"
      return 0
    fi
    # Holder died without running its trap (SIGKILL, container restart).
    log "apply-rules: clearing stale lock (pid ${_lpid} gone)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || { log "apply-rules: cannot create $LOCK_DIR"; return 1; }
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
  fi

  # Copy-detection below joins INBOX rows to their copies via extBodyKey
  # (copies share the body blob), but maddy's schema indexes only the msgs
  # PK and (mboxId, seen) — so every correlated EXISTS was a full scan of
  # all 12768 msgs rows, 4147 times over. MEASURED 2026-08-24: the
  # fallback-only re-open query did not finish in 60s without this index
  # and takes 3s with it. IF NOT EXISTS makes it a no-op after the first
  # run; an extra index is transparent to maddy's own queries.
  sq "CREATE INDEX IF NOT EXISTS idx_msgs_extbodykey ON msgs(extBodyKey);" >/dev/null

  FILTER_BIN_DEFAULT=/usr/local/bin/mail-sieve-subset-delivery-time
  FILTER_BIN="${FILTER_BIN:-$FILTER_BIN_DEFAULT}"
  [ -x "$FILTER_BIN" ] || fail "filter binary not found/executable: $FILTER_BIN"
  command -v xxd       >/dev/null 2>&1 || fail "xxd not in PATH (apk add xxd)"
  command -v maddy     >/dev/null 2>&1 || fail "maddy CLI not in PATH"
  command -v md5sum    >/dev/null 2>&1 || fail "md5sum not in PATH"

  ACCT="$(jq -r '.account // empty' "$RULES")"
  [ -n "$ACCT" ] || fail "rules missing .account — cannot resolve user"

  USER_ID="$(sq "SELECT id FROM users WHERE username = '$ACCT'")"
  [ -n "$USER_ID" ] || fail "user not in DB: $ACCT"

  INBOX_ID="$(sq "SELECT id FROM mboxes WHERE uid = $USER_ID AND name = 'INBOX'")"
  [ -n "$INBOX_ID" ] || fail "INBOX not found for user $ACCT (uid=$USER_ID)"

  # routing_default in mail-rules.json is already the literal fallback
  # mailbox name (e.g. "91    📬 Others (fallback)") — there is no
  # .folders map to look it up through.
  FALLBACK_NAME="$(jq -r '.routing_default // empty' "$RULES")"
  FALLBACK_MBOXID=""
  if [ -n "$FALLBACK_NAME" ]; then
    fb_esc="$(printf '%s' "$FALLBACK_NAME" | sed "s/'/''/g")"
    FALLBACK_MBOXID="$(sq "SELECT id FROM mboxes WHERE uid = $USER_ID AND name = '$fb_esc'")"
  fi

  _BACKED_UP=0
  _ensure_writable_once() {
    if [ "$_BACKED_UP" = "0" ]; then
      ensure_writable
      _BACKED_UP=1
    fi
  }

  # ── Part 2: ruleset-change detection + fallback re-open ───────────
  STATE_FILE="$(dirname "$DB")/.apply-rules-ruleset.md5"
  RULESET_HASH="$(jq -Sc '{routing_default, rules}' "$RULES" | md5sum | cut -d' ' -f1)"
  OLD_HASH=""
  [ -f "$STATE_FILE" ] && OLD_HASH="$(cat "$STATE_FILE" 2>/dev/null || true)"

  if [ -n "$OLD_HASH" ] && [ "$OLD_HASH" != "$RULESET_HASH" ] && [ -n "$FALLBACK_MBOXID" ]; then
    log "apply-rules: ruleset changed ($(printf '%.8s' "$OLD_HASH") → $(printf '%.8s' "$RULESET_HASH")) — checking fallback-only messages to re-open"

    REOPEN_IDS_FILE="$(mktemp)"
    sq "SELECT m.msgId FROM msgs m
        WHERE m.mboxId = $INBOX_ID
          AND EXISTS (
            SELECT 1 FROM flags f
            WHERE f.mboxId = m.mboxId AND f.msgId = m.msgId AND f.flag = '\$distributed'
          )
          AND EXISTS (
            SELECT 1 FROM msgs c
            WHERE c.mboxId = $FALLBACK_MBOXID AND c.extBodyKey = m.extBodyKey
          )
          AND NOT EXISTS (
            SELECT 1 FROM msgs c
            JOIN mboxes mb ON mb.id = c.mboxId
            WHERE mb.uid = $USER_ID AND mb.id != $FALLBACK_MBOXID
              AND mb.name GLOB '[0-9][0-9]*'
              AND c.extBodyKey = m.extBodyKey
          )" > "$REOPEN_IDS_FILE"
    REOPEN_COUNT="$(wc -l < "$REOPEN_IDS_FILE" 2>/dev/null || echo 0)"

    if [ "$REOPEN_COUNT" -gt 0 ]; then
      if [ "$DRY_RUN" = "1" ]; then
        log "  [dry-run] would re-open $REOPEN_COUNT fallback-only messages for re-evaluation"
      else
        _ensure_writable_once
        RTX="$(mktemp)"
        {
          echo "BEGIN IMMEDIATE TRANSACTION;"
          echo "CREATE TEMP TABLE _reopen(msgId BIGINT PRIMARY KEY);"
          awk 'NF { printf "INSERT INTO _reopen VALUES(%s);\n", $0 }' "$REOPEN_IDS_FILE"
          echo "DELETE FROM flags WHERE mboxId = $INBOX_ID AND flag = '\$distributed' AND msgId IN (SELECT msgId FROM _reopen);"
          echo "DROP TABLE _reopen;"
          echo "COMMIT;"
        } > "$RTX"
        sqlite3 "$DB" < "$RTX"
        rm -f "$RTX"
        log "  re-opened $REOPEN_COUNT fallback-only messages (cleared \$distributed)"
      fi
    else
      log "  no fallback-only messages to re-open"
    fi
    rm -f "$REOPEN_IDS_FILE"
  elif [ -z "$OLD_HASH" ]; then
    log "apply-rules: no prior ruleset state ($STATE_FILE) — first run, recording hash only, no re-open"
  fi

  # Candidates: INBOX rows WITHOUT $distributed keyword.
  TOTAL="$(sq "SELECT COUNT(*) FROM msgs m
              WHERE m.mboxId = $INBOX_ID
                AND NOT EXISTS (
                  SELECT 1 FROM flags f
                  WHERE f.mboxId = m.mboxId AND f.msgId = m.msgId
                    AND f.flag = '\$distributed'
                )")"
  log "apply-rules: INBOX has $TOTAL undistributed messages (user=$ACCT)"
  if [ "$TOTAL" -eq 0 ]; then
    log "  nothing to do"
    _resync_msgs_count "$USER_ID"
    [ "$DRY_RUN" = "1" ] || printf '%s\n' "$RULESET_HASH" > "$STATE_FILE"
    return 0
  fi

  _ensure_writable_once

  PLAN="$(mktemp)"   # cols: target_folder \t msgId \t comma-separated-flags
  SCAN="$(mktemp)"   # SQLite output — read via redirection so SCANNED
                     # propagates and loop body's exit status is the
                     # parent shell's (controlled with trailing `:`).
  SCANNED=0

  sq "SELECT m.msgId, hex(m.cachedHeader)
      FROM msgs m
      WHERE m.mboxId = $INBOX_ID
        AND NOT EXISTS (
          SELECT 1 FROM flags f
          WHERE f.mboxId = m.mboxId AND f.msgId = m.msgId
            AND f.flag = '\$distributed'
        )" > "$SCAN"

  while IFS='|' read -r msgid hex; do
    [ -z "$msgid" ] && continue
    # MAIL_SIEVE_STRATEGY=split → delivery-time emits the routing
    # decision (matched folder, or routing_default) instead of "INBOX".
    # cachedHeader is JSON ({"From":["…"], …}); flatten to RFC822 first.
    output="$(
      {
        printf '%s' "$hex" | xxd -r -p \
          | jq -r 'to_entries[] | "\(.key): \(.value | join(", "))"'
        printf '\n\n'
      } | MAIL_SIEVE_STRATEGY=split "$FILTER_BIN" "$ACCT" "" "" "" 2>/dev/null
    )"
    target="$(printf '%s' "$output" | awk 'NR==1')"
    flags="$(printf '%s' "$output" | awk 'NR>1 && NF' | paste -sd, -)"
    if [ -n "$target" ] && [ "$target" != "INBOX" ]; then
      printf '%s\t%s\t%s\n' "$target" "$msgid" "$flags" >> "$PLAN"
    fi
    SCANNED=$((SCANNED + 1))
    if [ $((SCANNED % 200)) -eq 0 ]; then
      log "  scanned $SCANNED / $TOTAL…"
    fi
    : # body must exit 0 (set -e + modulo short-circuit pitfall)
  done < "$SCAN"
  rm -f "$SCAN"

  PLAN_COUNT="$(wc -l < "$PLAN" 2>/dev/null || echo 0)"
  log "  scan complete — scanned $SCANNED rows, $PLAN_COUNT route to category folders"

  if [ "$PLAN_COUNT" -gt 0 ]; then
    log "  plan by destination folder:"
    PLAN_SUMMARY="$(mktemp)"
    awk -F'\t' '{ c[$1]++ } END { for (k in c) print c[k] "\t" k }' "$PLAN" \
      | sort -rn > "$PLAN_SUMMARY"
    while IFS=$(printf '\t') read -r nrows folder; do
      log "    $nrows  →  $folder"
    done < "$PLAN_SUMMARY"
    rm -f "$PLAN_SUMMARY"

    if [ "$DRY_RUN" = "1" ]; then
      log "  [dry-run] no copies performed — re-run without --dry-run to apply"
      rm -f "$PLAN"
      return 0
    fi

    # Build SQL transaction in a temp file. Per target: pre-allocate UIDs
    # in shell starting from mboxes.uidnext, increment per row, bump
    # uidnext + msgsCount by N at the end. Each per-msg block:
    #   - INSERT msgs (copy of source row, fresh msgId, seen=0 recent=1)
    #   - UPDATE extKeys.refs += 1 (blob shared, no on-disk duplication)
    #   - INSERT flags for rule-derived keywords on the copy (no \Seen)
    #   - INSERT \Seen + $distributed on INBOX original
    #   - UPDATE msgs.seen=1 on INBOX original
    SQLF="$(mktemp)"
    echo "BEGIN IMMEDIATE TRANSACTION;" > "$SQLF"

    TARGETS_FILE="$(mktemp)"
    awk -F'\t' '{ print $1 }' "$PLAN" | sort -u > "$TARGETS_FILE"
    COPIED_TOTAL=0
    SKIPPED_TOTAL=0
    PRUNE_CANDIDATES="$(mktemp)"   # src msgIds copied into a real (non-fallback) folder this run

    while IFS= read -r target; do
      [ -z "$target" ] && continue
      target_esc="$(printf '%s' "$target" | sed "s/'/''/g")"
      target_mboxId="$(sq "SELECT id FROM mboxes WHERE uid = $USER_ID AND name = '$target_esc'")"
      if [ -z "$target_mboxId" ]; then
        nmissing="$(awk -F'\t' -v t="$target" '$1==t { c++ } END { print c+0 }' "$PLAN")"
        err "target mailbox missing — skipping $nmissing msgs → '$target'"
        SKIPPED_TOTAL=$((SKIPPED_TOTAL + nmissing))
        : ; continue
      fi
      start_uid="$(sq "SELECT uidnext FROM mboxes WHERE id = $target_mboxId")"

      PER_TGT="$(mktemp)"
      awk -F'\t' -v t="$target" '$1==t { print $2 "\t" $3 }' "$PLAN" > "$PER_TGT"

      # Idempotency (Part 1): rows whose body (extBodyKey) is already
      # present in the target mailbox must not be copied again — this
      # is what makes re-opening a message (Part 2) safe to repeat.
      DUP_IDS="$(mktemp)"
      MSGIDS_CSV="$(awk -F'\t' '{ print $1 }' "$PER_TGT" | paste -sd, -)"
      if [ -n "$MSGIDS_CSV" ]; then
        sq "SELECT m.msgId FROM msgs m
            WHERE m.mboxId = $INBOX_ID AND m.msgId IN ($MSGIDS_CSV)
              AND m.extBodyKey IS NOT NULL
              AND EXISTS (SELECT 1 FROM msgs t WHERE t.mboxId = $target_mboxId AND t.extBodyKey = m.extBodyKey)" > "$DUP_IDS"
      fi
      N_DUP="$(wc -l < "$DUP_IDS" 2>/dev/null || echo 0)"
      if [ "$N_DUP" -gt 0 ]; then
        SKIPPED_TOTAL=$((SKIPPED_TOTAL + N_DUP))
        log "  idempotency: $N_DUP already have a body-copy in '$target' — skipping duplicate INSERT (INBOX original still marked processed)"
      fi

      n=0
      while IFS=$(printf '\t') read -r src_msgid src_flags; do
        if grep -qxF "$src_msgid" "$DUP_IDS" 2>/dev/null; then
          # Body already filed here — just mark the INBOX original
          # processed; do NOT insert a second copy.
          cat <<SQL
INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES ($INBOX_ID, $src_msgid, '\Seen');
INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES ($INBOX_ID, $src_msgid, '\$distributed');
UPDATE msgs SET seen = 1 WHERE mboxId = $INBOX_ID AND msgId = $src_msgid;
SQL
          continue
        fi

        new_uid=$((start_uid + n))
        n=$((n + 1))

        cat <<SQL
INSERT INTO msgs (mboxId, msgId, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, seen, recent, compressAlgo)
SELECT $target_mboxId, $new_uid, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, 0, 1, compressAlgo
  FROM msgs WHERE mboxId = $INBOX_ID AND msgId = $src_msgid;
UPDATE extKeys SET refs = refs + 1
 WHERE id = (SELECT extBodyKey FROM msgs
              WHERE mboxId = $INBOX_ID AND msgId = $src_msgid AND extBodyKey IS NOT NULL);
INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES ($INBOX_ID, $src_msgid, '\Seen');
INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES ($INBOX_ID, $src_msgid, '\$distributed');
UPDATE msgs SET seen = 1 WHERE mboxId = $INBOX_ID AND msgId = $src_msgid;
SQL

        if [ -n "$src_flags" ]; then
          # Per-flag inserts on the COPY (one row per keyword, no \Seen).
          printf '%s\n' "$src_flags" | tr ',' '\n' | while IFS= read -r f; do
            [ -z "$f" ] && continue
            f_esc="$(printf '%s' "$f" | sed "s/'/''/g")"
            printf "INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES (%s, %s, '%s');\n" \
              "$target_mboxId" "$new_uid" "$f_esc"
          done
        fi

        if [ "$PRUNE_FALLBACK" = "1" ] && [ -n "$FALLBACK_MBOXID" ] && [ "$target_mboxId" != "$FALLBACK_MBOXID" ]; then
          printf '%s\n' "$src_msgid" >> "$PRUNE_CANDIDATES"
        fi
      done >> "$SQLF" < "$PER_TGT"
      rm -f "$PER_TGT" "$DUP_IDS"

      printf 'UPDATE mboxes SET uidnext = uidnext + %d, msgsCount = msgsCount + %d WHERE id = %s;\n' \
        "$n" "$n" "$target_mboxId" >> "$SQLF"
      COPIED_TOTAL=$((COPIED_TOTAL + n))
      :
    done < "$TARGETS_FILE"

    echo "COMMIT;" >> "$SQLF"
    log "  applying SQL transaction ($COPIED_TOTAL copy ops)…"
    sqlite3 "$DB" < "$SQLF"
    rm -f "$SQLF" "$TARGETS_FILE"

    log "apply-rules: copied=$COPIED_TOTAL skipped=$SKIPPED_TOTAL of $PLAN_COUNT planned"

    # Part 3 (default OFF): prune the now-redundant fallback copy of any
    # message just filed into a real category folder this run. Not
    # wired into the DAG — opt-in via --prune-fallback / PRUNE_FALLBACK=1.
    if [ "$PRUNE_FALLBACK" = "1" ] && [ -n "$FALLBACK_MBOXID" ] && [ -s "$PRUNE_CANDIDATES" ]; then
      PTX="$(mktemp)"
      echo "BEGIN IMMEDIATE TRANSACTION;" > "$PTX"
      PRUNED=0
      while IFS= read -r src_msgid; do
        [ -z "$src_msgid" ] && continue
        cat <<SQL >> "$PTX"
DELETE FROM flags WHERE mboxId = $FALLBACK_MBOXID AND msgId IN (
  SELECT msgId FROM msgs WHERE mboxId = $FALLBACK_MBOXID
    AND extBodyKey = (SELECT extBodyKey FROM msgs WHERE mboxId = $INBOX_ID AND msgId = $src_msgid)
);
UPDATE extKeys SET refs = refs - 1
 WHERE id = (SELECT extBodyKey FROM msgs WHERE mboxId = $INBOX_ID AND msgId = $src_msgid)
   AND EXISTS (
     SELECT 1 FROM msgs WHERE mboxId = $FALLBACK_MBOXID
       AND extBodyKey = (SELECT extBodyKey FROM msgs WHERE mboxId = $INBOX_ID AND msgId = $src_msgid)
   );
DELETE FROM msgs WHERE mboxId = $FALLBACK_MBOXID
  AND extBodyKey = (SELECT extBodyKey FROM msgs WHERE mboxId = $INBOX_ID AND msgId = $src_msgid);
SQL
        PRUNED=$((PRUNED + 1))
      done < "$PRUNE_CANDIDATES"
      echo "COMMIT;" >> "$PTX"
      log "  prune-fallback: removing redundant fallback copies for $PRUNED newly-categorized messages…"
      sqlite3 "$DB" < "$PTX"
      rm -f "$PTX"
    fi
    rm -f "$PRUNE_CANDIDATES"
  fi

  _resync_msgs_count "$USER_ID"
  [ "$DRY_RUN" = "1" ] || printf '%s\n' "$RULESET_HASH" > "$STATE_FILE"
  rm -f "$PLAN"
}

# Recompute mboxes.msgsCount from canonical msgs (idempotent, sub-second).
# Maddy maintains the cache lazily on its own write paths; any SQL-direct
# write (here, dedupe, cleanup-mailboxes, integrity-fix) bypasses that
# path and leaves the per-mailbox counter stale until next sync.
_resync_msgs_count() {
  uid="$1"
  log "  recomputing mboxes.msgsCount counters from msgs (cache resync)…"
  sqlite3 "$DB" <<SQL
BEGIN IMMEDIATE TRANSACTION;
UPDATE mboxes SET msgsCount = (
  SELECT COUNT(*) FROM msgs WHERE msgs.mboxId = mboxes.id
) WHERE uid = $uid;
COMMIT;
SQL
}

cmd_reseed_inbox_archive() {
  # One-shot history backfill. Walks every non-system mailbox of the
  # configured account; for each msg whose Message-Id (extracted from
  # cachedHeader JSON) is NOT already present in INBOX, COPIES the row
  # into INBOX with \Seen + $distributed. After this runs, INBOX truly
  # is the chronological archive of every message the user ever
  # received. Runs idempotent — re-running is a no-op.
  #
  # System mailboxes excluded: INBOX itself, Sent, Drafts, Trash, Junk.
  # (configurable via --include-system, future.)
  log "reseed-inbox-archive: backfill INBOX with copies of every non-system mailbox msg"

  ACCT="$(jq -r '.account // empty' "$RULES")"
  [ -n "$ACCT" ] || fail "rules missing .account"
  USER_ID="$(sq "SELECT id FROM users WHERE username = '$ACCT'")"
  [ -n "$USER_ID" ] || fail "user not in DB: $ACCT"
  INBOX_ID="$(sq "SELECT id FROM mboxes WHERE uid = $USER_ID AND name = 'INBOX'")"
  [ -n "$INBOX_ID" ] || fail "INBOX not found"

  ensure_writable

  # Build a set of Message-Ids already in INBOX (the dedup key).
  EXISTING="$(mktemp)"
  sq "SELECT json_extract(cachedHeader, '\$.\"Message-Id\"[0]')
      FROM msgs WHERE mboxId = $INBOX_ID
        AND json_extract(cachedHeader, '\$.\"Message-Id\"[0]') IS NOT NULL" \
    | sort -u > "$EXISTING"
  log "  INBOX already contains $(wc -l < "$EXISTING") distinct Message-Ids"

  # Source set: all non-system mailbox msgs.
  SRC="$(mktemp)"
  sq "SELECT m.id || '|' || msg.msgId || '|' ||
             COALESCE(json_extract(msg.cachedHeader, '\$.\"Message-Id\"[0]'), '')
      FROM msgs msg
      JOIN mboxes m ON m.id = msg.mboxId
      WHERE m.uid = $USER_ID
        AND m.name NOT IN ('INBOX','Sent','Drafts','Trash','Junk')" > "$SRC"
  TOTAL_SRC="$(wc -l < "$SRC")"
  log "  candidate rows from non-system folders: $TOTAL_SRC"

  if [ "$TOTAL_SRC" -eq 0 ]; then
    rm -f "$EXISTING" "$SRC"
    log "  nothing to reseed"
    _resync_msgs_count "$USER_ID"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    NEW="$(awk -F'|' 'NF==3 && $3 != ""' "$SRC" \
            | sort -t'|' -k3,3 -u \
            | awk -F'|' -v existing="$EXISTING" 'BEGIN { while ((getline l < existing) > 0) seen[l]=1 } !($3 in seen)' \
            | wc -l)"
    log "  [dry-run] would copy $NEW unique-Message-Id rows into INBOX"
    rm -f "$EXISTING" "$SRC"
    return 0
  fi

  # Pre-allocate INBOX UIDs in shell starting from current uidnext.
  start_uid="$(sq "SELECT uidnext FROM mboxes WHERE id = $INBOX_ID")"

  # Walk SRC; emit one COPY-into-INBOX SQL block per unique Message-Id
  # not already in INBOX. dedupe-key = Message-Id (RFC 5322 globally
  # unique). Empty Message-Id → skip (can't dedup safely).
  SQLF="$(mktemp)"
  echo "BEGIN IMMEDIATE TRANSACTION;" > "$SQLF"

  awk -F'|' 'NF==3 && $3 != ""' "$SRC" \
    | sort -t'|' -k3,3 -u > "$SRC.uniq"

  COPIED=0
  while IFS='|' read -r src_mboxId src_msgid msgid_hdr; do
    [ -z "$msgid_hdr" ] && continue
    if grep -qxF "$msgid_hdr" "$EXISTING"; then
      continue
    fi
    new_uid=$((start_uid + COPIED))
    COPIED=$((COPIED + 1))

    cat <<SQL
INSERT INTO msgs (mboxId, msgId, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, seen, recent, compressAlgo)
SELECT $INBOX_ID, $new_uid, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, 1, 0, compressAlgo
  FROM msgs WHERE mboxId = $src_mboxId AND msgId = $src_msgid;
UPDATE extKeys SET refs = refs + 1
 WHERE id = (SELECT extBodyKey FROM msgs
              WHERE mboxId = $src_mboxId AND msgId = $src_msgid AND extBodyKey IS NOT NULL);
INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES ($INBOX_ID, $new_uid, '\Seen');
INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES ($INBOX_ID, $new_uid, '\$distributed');
SQL
    :
  done >> "$SQLF" < "$SRC.uniq"
  rm -f "$SRC.uniq"

  if [ "$COPIED" -gt 0 ]; then
    cat >> "$SQLF" <<SQL
UPDATE mboxes SET uidnext = uidnext + $COPIED, msgsCount = msgsCount + $COPIED WHERE id = $INBOX_ID;
SQL
  fi

  echo "COMMIT;" >> "$SQLF"
  log "  applying SQL transaction ($COPIED copy ops)…"
  sqlite3 "$DB" < "$SQLF"
  rm -f "$SQLF" "$EXISTING" "$SRC"

  log "reseed-inbox-archive: backfilled $COPIED messages into INBOX"
  _resync_msgs_count "$USER_ID"
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
  integrity-check)        cmd_integrity_check ;;
  integrity-fix)          cmd_integrity_fix ;;
  dedupe)                 cmd_dedupe ;;
  cleanup-mailboxes)      cmd_cleanup_mailboxes ;;
  apply-rules)            cmd_apply_rules ;;
  reseed-inbox-archive)   cmd_reseed_inbox_archive ;;
  all)                    cmd_all ;;
  *)                      fail "unknown subcommand: $SUBCMD (run --help)" ;;
esac
