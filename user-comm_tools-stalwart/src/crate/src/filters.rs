//! Dynamic cross-cutting filter views (`A*`/`B*`/`C*`/`D*`).
//!
//! Routing is owned entirely by the native Sieve (`_shared/lib/mail-rules.nix`
//! `::toSieve`): every inbound email lands in INBOX (read) plus exactly one
//! numeric `1*`-`9*` category folder as an UNREAD copy. This module never
//! routes and never touches keywords.
//!
//! It maintains membership of the filter mailboxes over the messages already
//! living in the numeric folders, using JMAP multi-mailbox membership — the
//! existing message is added to the view mailbox, so there are no copies and
//! no `$seen`/`$Sorted` changes. Membership is both added AND removed each
//! poll so time and read-state windows stay current.

use anyhow::Result;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

use crate::jmap::{BodyPart, Client, Email, Mailbox};
use crate::rules::{Predicate, Rules, View};

/// Emails per `Email/get` / `Email/set` call.
const BATCH_SIZE: usize = 100;

const EMAIL_PROPS: &[&str] = &[
    "size",
    "receivedAt",
    "keywords",
    "mailboxIds",
    "hasAttachment",
    "bodyStructure",
];

/// True if the email has a real (non-inline) attachment.
///
/// Prefers JMAP's `hasAttachment` when the server sent it; otherwise walks
/// `bodyStructure` for a part with an `attachment` disposition or a filename.
fn has_attachment(em: &Email) -> bool {
    match em.has_attachment {
        Some(v) => v,
        None => !attachment_types(em).is_empty(),
    }
}

/// MIME `type`s of the attachment parts in `bodyStructure`, lowercased.
fn attachment_types(em: &Email) -> HashSet<String> {
    fn walk(part: &BodyPart, out: &mut HashSet<String>) {
        let disp = part.disposition.as_deref().unwrap_or("").to_ascii_lowercase();
        if disp == "attachment" || part.name.is_some() {
            if let Some(t) = &part.mime_type {
                out.insert(t.to_ascii_lowercase());
            }
        }
        for sub in &part.sub_parts {
            walk(sub, out);
        }
    }
    let mut out = HashSet::new();
    if let Some(root) = &em.body_structure {
        walk(root, &mut out);
    }
    out
}

/// Parse a JMAP UTCDate (RFC 3339, e.g. `2026-06-18T10:20:30Z`) to epoch secs.
fn parse_utcdate(value: &str) -> Option<f64> {
    let v = value.trim();
    if v.is_empty() {
        return None;
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(v) {
        return Some(dt.timestamp() as f64);
    }
    // The Python accepted an offset-less timestamp via fromisoformat; keep
    // that tolerance rather than silently dropping such a message from every
    // time-window view.
    chrono::DateTime::parse_from_rfc3339(&format!("{v}Z"))
        .ok()
        .map(|dt| dt.timestamp() as f64)
}

/// Evaluate one filter predicate against an `Email/get` object.
///
/// Size views must tile the axis exactly once. All three size predicates are
/// half-open `[lo, hi)` so a message on a boundary lands in exactly one
/// bucket; `SizeRange` used to be fully closed, so a message of exactly
/// 10485760 bytes matched both "Medium" `[1MB,10MB]` and "Large" `[10MB,inf)`
/// and was filed into two folders.
pub fn email_matches(em: &Email, predicate: &Predicate, now: f64) -> bool {
    let size = em.size;
    match predicate {
        Predicate::SizeMin { bytes } => size >= *bytes,
        Predicate::SizeMax { bytes } => size < *bytes,
        Predicate::SizeRange { min, max } => size >= *min && size < *max,
        Predicate::NewerThanHours { hours } => match em
            .received_at
            .as_deref()
            .and_then(parse_utcdate)
        {
            Some(ts) => (now - ts) <= hours * 3600.0,
            None => false,
        },
        Predicate::Unread => !em.keywords.get("$seen").copied().unwrap_or(false),
        Predicate::HasAttachment => has_attachment(em),
        Predicate::AttachType { values } => {
            let types = attachment_types(em);
            values
                .iter()
                .any(|v| types.contains(&v.to_ascii_lowercase()))
        }
    }
}

/// Reconcile membership of every filter-view mailbox. Returns emails updated.
pub fn maintain_filters(
    client: &Client,
    rules: &Rules,
    name_to_id: &HashMap<String, String>,
    mailboxes: &[Mailbox],
) -> Result<usize> {
    let views = &rules.filters.views;
    if views.is_empty() {
        return Ok(0);
    }

    let src_re = Regex::new(&rules.filters.source_folder_regex)?;

    // 1. Source mailboxes = those whose NAME matches the regex.
    let source_ids: Vec<String> = mailboxes
        .iter()
        .filter(|mb| src_re.is_match(&mb.name))
        .map(|mb| mb.id.clone())
        .collect();
    if source_ids.is_empty() {
        return Ok(0);
    }

    // View folder name -> mailbox id (skip views whose mailbox isn't created).
    let view_ids: HashMap<&str, &str> = views
        .iter()
        .filter_map(|v| {
            name_to_id
                .get(&v.folder)
                .map(|id| (v.folder.as_str(), id.as_str()))
        })
        .collect();
    if view_ids.is_empty() {
        return Ok(0);
    }

    // Static views (size, attachments) are properties of the message and never
    // change; volatile views (time windows, read state) must be recomputed
    // every poll. Recomputing all of them for every message on a 30s cycle was
    // mostly wasted work, and that waste is what made paging the full mailbox
    // costly.
    let volatile_views: Vec<&View> = views.iter().filter(|v| v.volatile).collect();

    // The partition axis tiles its range, so every message sits in exactly one
    // of its buckets. Membership of that axis is therefore a reliable "static
    // views already computed" sentinel, and it self-heals: a message missing
    // it simply gets recomputed.
    let sentinel_ids: HashSet<&str> = match &rules.filters.partition_axis {
        Some(axis) => views
            .iter()
            .filter(|v| v.axis.as_deref() == Some(axis.as_str()))
            .filter_map(|v| view_ids.get(v.folder.as_str()).copied())
            .collect(),
        None => HashSet::new(),
    };

    // 2. Union of emails in any source folder.
    let email_ids = client.email_query_in(&source_ids, None)?;
    if email_ids.is_empty() {
        return Ok(0);
    }

    let now = crate::now_epoch();
    let mut updates: Map<String, Value> = Map::new();
    let mut n_static = 0usize;

    for batch in email_ids.chunks(BATCH_SIZE) {
        let emails = client.email_get(batch, EMAIL_PROPS)?;

        for em in &emails {
            let mut desired: HashMap<String, bool> = em.mailbox_ids.clone();

            // Only compute static views when this message has never had them
            // (or the sentinel axis isn't deployed, in which case always).
            let needs_static = sentinel_ids.is_empty()
                || !sentinel_ids.iter().any(|s| em.mailbox_ids.contains_key(*s));
            if needs_static {
                n_static += 1;
            }
            let todo: Vec<&View> = if needs_static {
                views.iter().collect()
            } else {
                volatile_views.clone()
            };

            // Only emit an update if a VIEW-mailbox bit actually flipped.
            // `desired` starts as an exact copy of the current membership and
            // this loop is the only thing that touches it, so tracking the
            // flips directly is equivalent to diffing the two sets — and it
            // guarantees non-view membership (numeric folders, INBOX) is never
            // rewritten just because it was re-serialised.
            let mut changed = false;
            for view in todo {
                let Some(vid) = view_ids.get(view.folder.as_str()).copied() else {
                    continue;
                };
                let want = email_matches(em, &view.predicate, now);
                let have = desired.contains_key(vid);
                if want && !have {
                    desired.insert(vid.to_string(), true);
                    changed = true;
                } else if !want && have {
                    desired.remove(vid);
                    changed = true;
                }
            }

            if changed {
                updates.insert(em.id.clone(), json!({ "mailboxIds": desired }));
            }
        }
    }

    let mut total = 0usize;
    if !updates.is_empty() {
        let items: Vec<(String, Value)> = updates.into_iter().collect();
        for chunk in items.chunks(BATCH_SIZE) {
            let patch: Map<String, Value> = chunk.iter().cloned().collect();
            let result = client.email_set(patch)?;
            total += result.updated.len();
            for (eid, err) in result.not_updated.iter().take(3) {
                tracing::warn!("Filter update failed {eid}: {err}");
            }
        }
    }

    if total > 0 {
        tracing::info!(
            "Filter views: updated membership on {total} emails \
             ({} scanned, {n_static} needed static recompute, {} volatile views)",
            email_ids.len(),
            volatile_views.len()
        );
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn email(v: Value) -> Email {
        serde_json::from_value(v).expect("email fixture")
    }

    fn pred(v: Value) -> Predicate {
        serde_json::from_value(v).expect("predicate fixture")
    }

    #[test]
    fn size_buckets_tile_exactly_once() {
        // The regression that filed a 10MB message into two folders: the three
        // size views must partition the axis, so every size matches exactly one.
        let views = [
            pred(json!({"type": "size_max",   "bytes": 1048576})),
            pred(json!({"type": "size_range", "min": 1048576, "max": 10485760})),
            pred(json!({"type": "size_min",   "bytes": 10485760})),
        ];
        for size in [0u64, 1, 1048575, 1048576, 1048577, 10485759, 10485760, 10485761, 1 << 30] {
            let em = email(json!({"id": "e", "size": size}));
            let hits = views.iter().filter(|p| email_matches(&em, p, 0.0)).count();
            assert_eq!(hits, 1, "size {size} matched {hits} buckets, expected exactly 1");
        }
    }

    #[test]
    fn unread_is_absence_of_seen() {
        let seen = email(json!({"id": "e", "keywords": {"$seen": true}}));
        let unseen = email(json!({"id": "e", "keywords": {"$flagged": true}}));
        let none = email(json!({"id": "e"}));
        let p = pred(json!({"type": "unread"}));
        assert!(!email_matches(&seen, &p, 0.0));
        assert!(email_matches(&unseen, &p, 0.0));
        assert!(email_matches(&none, &p, 0.0));
    }

    #[test]
    fn newer_than_hours_uses_received_at() {
        let p = pred(json!({"type": "newer_than_hours", "hours": 24}));
        // 2026-06-18T10:20:30Z
        let em = email(json!({"id": "e", "receivedAt": "2026-06-18T10:20:30Z"}));
        let ts = parse_utcdate("2026-06-18T10:20:30Z").unwrap();
        assert!(email_matches(&em, &p, ts + 3600.0), "1h old must match 24h window");
        assert!(email_matches(&em, &p, ts + 24.0 * 3600.0), "exactly 24h is inclusive");
        assert!(!email_matches(&em, &p, ts + 24.0 * 3600.0 + 1.0), "25h must not match");
        // An unparseable/absent date must not silently join every time view.
        let undated = email(json!({"id": "e"}));
        assert!(!email_matches(&undated, &p, ts));
    }

    #[test]
    fn attachment_falls_back_to_body_structure() {
        let p = pred(json!({"type": "has_attachment"}));
        // hasAttachment wins when present, even against a matching body.
        let flagged_false = email(json!({
            "id": "e", "hasAttachment": false,
            "bodyStructure": {"type": "application/pdf", "disposition": "attachment"}
        }));
        assert!(!email_matches(&flagged_false, &p, 0.0));
        // Absent -> walk subParts, including a filename with no disposition.
        let nested = email(json!({"id": "e", "bodyStructure": {
            "type": "multipart/mixed",
            "subParts": [
                {"type": "text/plain"},
                {"type": "image/png", "name": "shot.png"}
            ]
        }}));
        assert!(email_matches(&nested, &p, 0.0));
        let inline_only = email(json!({"id": "e", "bodyStructure": {
            "type": "multipart/alternative",
            "subParts": [{"type": "text/plain"}, {"type": "text/html"}]
        }}));
        assert!(!email_matches(&inline_only, &p, 0.0));
    }

    #[test]
    fn attach_type_matches_case_insensitively() {
        let p = pred(json!({"type": "attach_type", "values": ["APPLICATION/PDF"]}));
        let em = email(json!({"id": "e", "bodyStructure": {
            "type": "multipart/mixed",
            "subParts": [{"type": "Application/Pdf", "disposition": "ATTACHMENT"}]
        }}));
        assert!(email_matches(&em, &p, 0.0));
    }

    #[test]
    fn unknown_predicate_type_is_a_load_error() {
        // The whole point of the tagged enum: the Python returned False here
        // and left a permanently empty folder that looked like a working one.
        let bad: Result<Predicate, _> = serde_json::from_value(json!({"type": "size_mn", "bytes": 1}));
        assert!(bad.is_err(), "a typo'd predicate type must fail to parse");
    }
}
