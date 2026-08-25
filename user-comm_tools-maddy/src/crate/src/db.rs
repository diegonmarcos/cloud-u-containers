//! Direct SQLite access to go-imap-sql's schema (observed against running
//! maddy 0.x, documented in mail-sieve-subset-post-hoc.sh's header):
//!   users(id, username, ...)
//!   mboxes(id PK, uid -> users.id, name UNIQUE(uid,name), uidnext, msgsCount)
//!   msgs(mboxId, msgId, date, bodyLen, mark, bodyStructure, cachedHeader,
//!        extBodyKey -> extKeys.id, seen, recent, compressAlgo,
//!        PK(mboxId,msgId))
//!   extKeys(id VARCHAR PK, refs)
//!   flags(mboxId, msgId, flag, FK -> msgs ON DELETE CASCADE)
//!
//! Every write here is the direct Rust equivalent of cmd_apply_rules() in
//! mail-sieve-subset-post-hoc.sh (SQL statements copied verbatim in intent,
//! not redesigned) — see that function's comment for the full step-by-step
//! rationale. Two deliberate differences from the bash version:
//!
//!   - No `.apply-rules.lock` guard: the bash lock existed because an
//!     external Dagu cron could overlap itself when an ssh call hung (see
//!     mail-apply-rules-loop.sh's header for the incident). This binary
//!     runs one `loop { run_once(); sleep(interval); }` in a single
//!     process — there is no second invocation that could ever run
//!     concurrently with the first, so the failure mode the lock guarded
//!     against cannot occur here.
//!   - Fallback-reopen "does this message already have a REAL copy"
//!     check no longer pattern-matches folder names against a numeric
//!     `[0-9][0-9]*` GLOB. That pattern matched the old 1*-9* routing
//!     scheme; Maddy now only routes into F0 sender folders (Fa.., not
//!     numeric), so the GLOB would silently never match anything and
//!     every message would look "fallback-only" forever. Replaced with
//!     "has a copy in any mailbox that isn't INBOX and isn't the
//!     configured fallback" -- correct regardless of what the category
//!     folders happen to be named.

use crate::email::Email;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn open(db_path: &str) -> anyhow::Result<Connection> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    Ok(conn)
}

pub fn find_user_id(conn: &Connection, account: &str) -> anyhow::Result<i64> {
    conn.query_row("SELECT id FROM users WHERE username = ?1", params![account], |r| r.get(0))
        .map_err(|e| anyhow::anyhow!("user not in DB: {account}: {e}"))
}

pub fn find_mailbox_id(conn: &Connection, user_id: i64, name: &str) -> anyhow::Result<Option<i64>> {
    Ok(conn
        .query_row(
            "SELECT id FROM mboxes WHERE uid = ?1 AND name = ?2",
            params![user_id, name],
            |r| r.get(0),
        )
        .optional()?)
}

/// FNV-1a — deterministic, dependency-free, sufficient for "did the
/// ruleset change" detection. Not meant to be collision-resistant against
/// an adversary, only against normal ruleset edits.
fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// Same idea as the bash version's `jq -Sc '{routing_default, rules}' |
/// md5sum`: hash the rules file's own bytes. This crate's state file is
/// independent of the retired bash cron's, so the exact algorithm doesn't
/// need to match — only "changed vs not" does. Re-reads the file rather
/// than hashing the already-parsed `Rules` so unrelated whitespace/key-
/// order changes in a re-render still count as "changed" defensively
/// (cheap either way, this runs once per poll interval, not per message).
pub fn ruleset_hash(rules_path: &str) -> anyhow::Result<u64> {
    let raw = std::fs::read(rules_path)?;
    Ok(fnv1a(&raw))
}

pub fn state_file_path(db_path: &str) -> String {
    let dir = Path::new(db_path).parent().unwrap_or(Path::new("/data"));
    dir.join(".apply-rules-ruleset.hash").to_string_lossy().into_owned()
}

pub fn read_state_hash(state_path: &str) -> Option<u64> {
    std::fs::read_to_string(state_path).ok()?.trim().parse().ok()
}

pub fn write_state_hash(state_path: &str, hash: u64) -> anyhow::Result<()> {
    std::fs::write(state_path, hash.to_string())?;
    Ok(())
}

/// `msgId`, raw `cachedHeader` bytes for every INBOX row not yet tagged
/// `$distributed`.
pub fn undistributed_inbox_rows(conn: &Connection, inbox_id: i64) -> anyhow::Result<Vec<(i64, Vec<u8>)>> {
    let mut stmt = conn.prepare(
        "SELECT m.msgId, m.cachedHeader FROM msgs m
         WHERE m.mboxId = ?1
           AND NOT EXISTS (
             SELECT 1 FROM flags f
             WHERE f.mboxId = m.mboxId AND f.msgId = m.msgId AND f.flag = '$distributed'
           )",
    )?;
    let rows = stmt
        .query_map(params![inbox_id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// INBOX msgIds already `$distributed`, with a copy in some mailbox that
/// is neither INBOX nor `fallback_id`, filed there via the SAME body
/// (extBodyKey) — i.e. genuinely re-evaluatable "fallback-only" rows.
pub fn fallback_only_distributed_ids(
    conn: &Connection,
    inbox_id: i64,
    fallback_id: i64,
) -> anyhow::Result<Vec<i64>> {
    let mut stmt = conn.prepare(
        "SELECT m.msgId FROM msgs m
         WHERE m.mboxId = ?1
           AND EXISTS (
             SELECT 1 FROM flags f
             WHERE f.mboxId = m.mboxId AND f.msgId = m.msgId AND f.flag = '$distributed'
           )
           AND EXISTS (
             SELECT 1 FROM msgs c
             WHERE c.mboxId = ?2 AND c.extBodyKey = m.extBodyKey
           )
           AND NOT EXISTS (
             SELECT 1 FROM msgs c
             WHERE c.mboxId != ?1 AND c.mboxId != ?2 AND c.extBodyKey = m.extBodyKey
           )",
    )?;
    let ids = stmt
        .query_map(params![inbox_id, fallback_id], |r| r.get::<_, i64>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ids)
}

pub fn clear_distributed(conn: &Connection, inbox_id: i64, ids: &[i64]) -> anyhow::Result<()> {
    if ids.is_empty() {
        return Ok(());
    }
    let tx = conn.unchecked_transaction()?;
    for id in ids {
        tx.execute(
            "DELETE FROM flags WHERE mboxId = ?1 AND msgId = ?2 AND flag = '$distributed'",
            params![inbox_id, id],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn backup(db_path: &str) -> anyhow::Result<()> {
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    let bak = format!("{db_path}.bak-{ts}");
    std::fs::copy(db_path, &bak)?;
    tracing::info!("backed up DB -> {bak}");

    // Retention: keep the newest 20 (mirrors the bash version's rationale
    // -- MEASURED 2026-08-24, 137 unpruned backups had eaten 87% of /data).
    let dir = Path::new(db_path).parent().unwrap_or(Path::new("/data"));
    let db_name = Path::new(db_path).file_name().and_then(|s| s.to_str()).unwrap_or("");
    let mut backups: Vec<(std::time::SystemTime, std::path::PathBuf)> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_name().to_str().is_some_and(|n| n.starts_with(&format!("{db_name}.bak-")))
        })
        .filter_map(|e| e.metadata().ok().and_then(|m| m.modified().ok()).map(|t| (t, e.path())))
        .collect();
    backups.sort_by_key(|(t, _)| std::cmp::Reverse(*t));
    for (_, path) in backups.into_iter().skip(20) {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

pub fn resync_msgs_count(conn: &Connection, user_id: i64) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE mboxes SET msgsCount = (
           SELECT COUNT(*) FROM msgs WHERE msgs.mboxId = mboxes.id
         ) WHERE uid = ?1",
        params![user_id],
    )?;
    Ok(())
}

/// One planned copy: source INBOX msgId -> target mailbox name.
pub struct Plan {
    pub target_folder: String,
    pub src_msg_id: i64,
}

/// Copies every planned message into its target mailbox (SQL-direct,
/// idempotent per body: a row already sharing extBodyKey with an existing
/// row in the target is not duplicated, the INBOX original is just marked
/// processed), then marks EVERY scanned INBOX original \Seen + $distributed
/// (including ones that matched nothing and stay in INBOX only). One
/// transaction for the whole batch.
pub fn apply_plan(
    conn: &mut Connection,
    inbox_id: i64,
    user_id: i64,
    plans: &[Plan],
    all_scanned_ids: &[i64],
) -> anyhow::Result<(usize, usize)> {
    let mut by_target: HashMap<&str, Vec<i64>> = HashMap::new();
    for p in plans {
        by_target.entry(p.target_folder.as_str()).or_default().push(p.src_msg_id);
    }

    let tx = conn.transaction()?;
    let mut copied = 0usize;
    let mut skipped = 0usize;

    for (target, msg_ids) in &by_target {
        let target_id: Option<i64> = tx
            .query_row(
                "SELECT id FROM mboxes WHERE uid = ?1 AND name = ?2",
                params![user_id, target],
                |r| r.get(0),
            )
            .optional()?;
        let Some(target_id) = target_id else {
            tracing::error!("target mailbox missing, skipping {} msg(s) -> {target}", msg_ids.len());
            skipped += msg_ids.len();
            continue;
        };

        let mut next_uid: i64 =
            tx.query_row("SELECT uidnext FROM mboxes WHERE id = ?1", params![target_id], |r| r.get(0))?;
        let mut n_inserted = 0i64;

        for &src_id in msg_ids {
            let dup: Option<i64> = tx
                .query_row(
                    "SELECT 1 FROM msgs m
                     WHERE m.mboxId = ?1 AND m.msgId = ?2 AND m.extBodyKey IS NOT NULL
                       AND EXISTS (SELECT 1 FROM msgs t WHERE t.mboxId = ?3 AND t.extBodyKey = m.extBodyKey)",
                    params![inbox_id, src_id, target_id],
                    |r| r.get(0),
                )
                .optional()?;

            if dup.is_some() {
                skipped += 1;
                continue;
            }

            tx.execute(
                "INSERT INTO msgs (mboxId, msgId, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, seen, recent, compressAlgo)
                 SELECT ?1, ?2, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, 0, 1, compressAlgo
                 FROM msgs WHERE mboxId = ?3 AND msgId = ?4",
                params![target_id, next_uid, inbox_id, src_id],
            )?;
            tx.execute(
                "UPDATE extKeys SET refs = refs + 1
                 WHERE id = (SELECT extBodyKey FROM msgs WHERE mboxId = ?1 AND msgId = ?2 AND extBodyKey IS NOT NULL)",
                params![inbox_id, src_id],
            )?;
            next_uid += 1;
            n_inserted += 1;
            copied += 1;
        }

        if n_inserted > 0 {
            tx.execute(
                "UPDATE mboxes SET uidnext = uidnext + ?1, msgsCount = msgsCount + ?1 WHERE id = ?2",
                params![n_inserted, target_id],
            )?;
        }
    }

    // Every scanned INBOX original gets marked processed, whether or not
    // it matched a route (routing_default's Fz fallback always matches
    // SOMETHING per the F axis design, but this stays correct even if a
    // future edit leaves a gap).
    for &id in all_scanned_ids {
        tx.execute(
            "INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES (?1, ?2, '\\Seen')",
            params![inbox_id, id],
        )?;
        tx.execute(
            "INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES (?1, ?2, '$distributed')",
            params![inbox_id, id],
        )?;
        tx.execute("UPDATE msgs SET seen = 1 WHERE mboxId = ?1 AND msgId = ?2", params![inbox_id, id])?;
    }

    tx.commit()?;
    Ok((copied, skipped))
}

pub fn parse_email(cached_header: &[u8]) -> anyhow::Result<Email> {
    Email::from_cached_header_json(cached_header)
}

/// `(id, name)` of every mailbox this user owns.
pub fn list_mailboxes(conn: &Connection, user_id: i64) -> anyhow::Result<Vec<(i64, String)>> {
    let mut stmt = conn.prepare("SELECT id, name FROM mboxes WHERE uid = ?1")?;
    let rows = stmt
        .query_map(params![user_id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Drops every mailbox this user owns that `valid` does not name, after
/// rehoming its mail into INBOX.
///
/// Maddy's folder set is meant to be exactly INBOX + the F0 sender folders
/// (+ IMAP's own system folders). Anything else is a leftover from an
/// earlier scheme — the numeric `1*`-`9*` folders this account accumulated
/// under the old split-delivery model, which Maddy no longer routes into.
///
/// MEASURED on oci-mail 2026-08-25 before writing this: 4392 of those
/// messages existed ONLY in a numeric folder, with no copy in INBOX (they
/// predate the unified-inbox switch, when delivery filed straight into the
/// category folder instead of INBOX). So a plain DROP would have destroyed
/// real mail. Every message is therefore COPIED into INBOX first (skipping
/// bodies INBOX already holds, matched on extBodyKey) and only then is the
/// folder emptied and removed. Mirrors what the Stalwart sorter's
/// `cleanup_stale` does on the JMAP side: move to INBOX, then destroy.
pub fn cleanup_stale_mailboxes(
    conn: &mut Connection,
    user_id: i64,
    inbox_id: i64,
    valid: &std::collections::HashSet<String>,
) -> anyhow::Result<(usize, usize)> {
    let stale: Vec<(i64, String)> = list_mailboxes(conn, user_id)?
        .into_iter()
        .filter(|(id, name)| *id != inbox_id && !valid.contains(name.as_str()))
        .collect();
    if stale.is_empty() {
        return Ok((0, 0));
    }

    let tx = conn.transaction()?;
    let mut rehomed = 0usize;

    let mut inbox_uid: i64 =
        tx.query_row("SELECT uidnext FROM mboxes WHERE id = ?1", params![inbox_id], |r| r.get(0))?;
    let start_uid = inbox_uid;

    for (mbox_id, name) in &stale {
        let ids: Vec<i64> = {
            let mut stmt = tx.prepare(
                "SELECT m.msgId FROM msgs m
                 WHERE m.mboxId = ?1
                   AND (m.extBodyKey IS NULL OR NOT EXISTS (
                     SELECT 1 FROM msgs i WHERE i.mboxId = ?2 AND i.extBodyKey = m.extBodyKey
                   ))",
            )?;
            // Bound to a local before leaving the block on purpose: with the
            // `?` in tail position the Try temporary outlives `stmt` and the
            // borrow checker rejects it (E0597 — `stmt` dropped while still
            // borrowed). The sibling query fns above use this same
            // let-then-return shape for the same reason.
            let rows = stmt
                .query_map(params![mbox_id, inbox_id], |r| r.get::<_, i64>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };

        for src_id in &ids {
            tx.execute(
                "INSERT INTO msgs (mboxId, msgId, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, seen, recent, compressAlgo)
                 SELECT ?1, ?2, date, bodyLen, mark, bodyStructure, cachedHeader, extBodyKey, 1, 0, compressAlgo
                 FROM msgs WHERE mboxId = ?3 AND msgId = ?4",
                params![inbox_id, inbox_uid, mbox_id, src_id],
            )?;
            tx.execute(
                "UPDATE extKeys SET refs = refs + 1
                 WHERE id = (SELECT extBodyKey FROM msgs WHERE mboxId = ?1 AND msgId = ?2 AND extBodyKey IS NOT NULL)",
                params![mbox_id, src_id],
            )?;
            // Rehomed mail is archive, not new work: mark it processed so
            // route_new_mail doesn't immediately re-file 4k messages into
            // the F folders on the very next poll.
            tx.execute(
                "INSERT OR IGNORE INTO flags (mboxId, msgId, flag) VALUES (?1, ?2, '$distributed')",
                params![inbox_id, inbox_uid],
            )?;
            inbox_uid += 1;
            rehomed += 1;
        }

        // extKeys.refs must come down for EVERY row about to be deleted,
        // not just the ones copied above — otherwise a body whose only
        // remaining reference was the duplicate we skipped leaks forever.
        tx.execute(
            "UPDATE extKeys SET refs = refs - 1
             WHERE id IN (SELECT extBodyKey FROM msgs WHERE mboxId = ?1 AND extBodyKey IS NOT NULL)",
            params![mbox_id],
        )?;
        // flags rows cascade on msgs delete (FK ON DELETE CASCADE).
        tx.execute("DELETE FROM msgs WHERE mboxId = ?1", params![mbox_id])?;
        tx.execute("DELETE FROM mboxes WHERE id = ?1", params![mbox_id])?;
        tracing::info!("cleanup: removed stale mailbox {name:?}");
    }

    if inbox_uid != start_uid {
        tx.execute(
            "UPDATE mboxes SET uidnext = ?1, msgsCount = msgsCount + ?2 WHERE id = ?3",
            params![inbox_uid, inbox_uid - start_uid, inbox_id],
        )?;
    }

    tx.commit()?;
    Ok((stale.len(), rehomed))
}
