//! Mailbox reconciliation: renames, ensure-exists, and stale cleanup.

use anyhow::Result;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

use crate::jmap::{Client, Mailbox, PAGE};
use crate::rules::Rules;

/// Mailbox names the server owns; never reaped, never renamed.
const SYSTEM_FOLDERS: &[&str] = &[
    "INBOX", "Sent", "Drafts", "Trash", "Junk", "Archive",
    "Sent Items", "Deleted Items", "Junk Mail", "Outbox", "Templates",
];

pub fn find_inbox_id(mailboxes: &[Mailbox]) -> Option<&str> {
    mailboxes
        .iter()
        .find(|mb| mb.role.as_deref() == Some("inbox") || mb.name == "INBOX")
        .map(|mb| mb.id.as_str())
}

/// Plans a single `Mailbox/set` batch: which mailboxes to create, which
/// misparented ones to move.
struct Planner<'a> {
    by_name: HashMap<&'a str, Vec<&'a Mailbox>>,
    creates: Map<String, Value>,
    updates: Map<String, Value>,
    counter: usize,
}

impl<'a> Planner<'a> {
    fn new(existing: &'a [Mailbox]) -> Self {
        let mut by_name: HashMap<&str, Vec<&Mailbox>> = HashMap::new();
        for mb in existing {
            by_name.entry(mb.name.as_str()).or_default().push(mb);
        }
        Self { by_name, creates: Map::new(), updates: Map::new(), counter: 0 }
    }

    /// Mailbox id for `(name, parent)`. Moves a straggler rather than creating
    /// a duplicate; queues a create (returning a `#ref`) when truly missing.
    fn pick_or_create(
        &mut self,
        name: &str,
        parent: Option<&str>,
        ref_prefix: &str,
        sort_order: u32,
    ) -> String {
        let id = {
            let candidates = self.by_name.get(name).map(Vec::as_slice).unwrap_or(&[]);
            // Prefer one already at the expected parent.
            let exact = candidates
                .iter()
                .find(|c| c.parent_id.as_deref() == parent)
                .map(|c| c.id.clone());
            match exact {
                Some(id) => Some((id, false)),
                // Otherwise reparent the first candidate (cheap fix for the
                // legacy-parent-with-valid-child layout). Never create a
                // duplicate — duplicates are what block the legacy parent from
                // ever being destroyed (`mailboxHasChild`).
                None => candidates.first().map(|stray| (stray.id.clone(), true)),
            }
        };

        self.counter += 1;
        match id {
            Some((id, false)) => id,
            Some((id, true)) => {
                self.updates.insert(id.clone(), json!({ "parentId": parent }));
                id
            }
            None => {
                // Truly missing — queue a create and hand back the JMAP
                // back-reference so children can be parented in the same batch.
                let r = format!("{ref_prefix}_{}", self.counter - 1);
                self.creates.insert(
                    r.clone(),
                    json!({ "name": name, "parentId": parent, "sortOrder": sort_order }),
                );
                format!("#{r}")
            }
        }
    }
}

/// Reconcile mailbox state with the rules.
///
/// Two steps: plan every `(name, parent)` the rules declare (preferring an
/// existing correctly-parented mailbox, else reparenting a straggler, else
/// queueing a create), then apply them in one `Mailbox/set`.
///
/// Returns `(name -> id, full mailbox list)`, both re-fetched after the set
/// call because `pick_or_create` hands back unresolved `#ref` placeholders.
pub fn ensure_mailboxes(
    client: &Client,
    rules: &Rules,
) -> Result<(HashMap<String, String>, Vec<Mailbox>)> {
    let existing = client.mailbox_get()?;
    let mut plan = Planner::new(&existing);

    // Routing targets — all at ROOT (parentId = None).
    for (i, folder) in rules.folders.values().enumerate() {
        plan.pick_or_create(folder, None, "inbox", i as u32 + 1);
    }

    // Two-level folder groups (e.g. "31 Cloud - Reports & CI" -> GH Workflows
    // / Cloud Reports / Rss Notifications). Real parent-child nesting, unlike
    // the flat `folders` loop above — sort_order continues from where that
    // loop left off so groups sort after the flat routing targets.
    let folders_len = rules.folders.len() as u32;
    for (gi, group) in rules.folder_groups.iter().enumerate() {
        let parent = plan.pick_or_create(&group.name, None, "foldergroup", folders_len + 1 + gi as u32);
        for (ci, child) in group.children.values().enumerate() {
            plan.pick_or_create(child, Some(&parent), &format!("foldergroup_{gi}"), ci as u32);
        }
    }

    // Visual section-header folders (flat ROOT siblings, NOT parents). They
    // sort alphabetically just before each numeric block (10 _ ADMIN < 11 ...)
    // so users get the same grouped layout Maddy ships. Not routing targets.
    for (j, label) in rules.folders_ui.iter().enumerate() {
        plan.pick_or_create(label, None, "section", 100 + j as u32);
    }

    // Dynamic filter views — flat ROOT mailboxes (section headers + one folder
    // per view). Membership is maintained by `maintain_filters`; here we only
    // ensure the mailboxes exist.
    for (k, label) in rules.filters.section_headers.iter().enumerate() {
        plan.pick_or_create(label, None, "filtersec", 200 + k as u32);
    }
    for (vi, view) in rules.filters.views.iter().enumerate() {
        plan.pick_or_create(&view.folder, None, "filterview", 300 + vi as u32);
    }

    if !plan.creates.is_empty() || !plan.updates.is_empty() {
        if !plan.creates.is_empty() {
            tracing::info!("Creating {} mailboxes...", plan.creates.len());
        }
        if !plan.updates.is_empty() {
            tracing::info!("Reparenting {} misparented mailboxes...", plan.updates.len());
        }
        let result = client.mailbox_set(Some(plan.creates), Some(plan.updates), None, false)?;
        for (r, err) in &result.not_created {
            tracing::warn!("Failed to create {r}: {err}");
        }
        for (mid, err) in &result.not_updated {
            tracing::warn!("Failed to reparent {mid}: {err}");
        }
    }

    // Always re-fetch — `pick_or_create` returned create-refs (`#ref_N`) for
    // missing mailboxes; those resolve to real ids only via a fresh
    // Mailbox/get.
    let existing = client.mailbox_get()?;
    let name_to_id = existing
        .iter()
        .map(|mb| (mb.name.clone(), mb.id.clone()))
        .collect();
    Ok((name_to_id, existing))
}

/// Reconcile mailbox names (`old -> new`) from `rules.folder_renames.map`.
///
/// Three cases, all idempotent:
///   1. old absent              -> nothing to do.
///   2. old present, new absent -> in-place `Mailbox/set` name update. JMAP
///      preserves the mailbox's emails and children, which is the whole point
///      versus create-new + reap-old.
///   3. old present, new present -> MERGE: move every email from old into new,
///      then destroy old.
///
/// Case 3 used to be a silent no-op ("rename only when new does not exist").
/// That stranded mail: once the new folder had been created by any other path
/// the rename never fired, and the old folder kept accumulating messages that
/// were invisible to every rule keyed on the new name. Observed in production
/// as 230 messages marooned in `Aa 📬 Others (fallback)` while
/// `91 📬 Others (fallback)` was the live target.
pub fn apply_renames(client: &Client, rules: &Rules, mailboxes: &[Mailbox]) -> Result<()> {
    let renames = &rules.folder_renames.map;
    if renames.is_empty() {
        return Ok(());
    }
    let by_name: HashMap<&str, &str> = mailboxes
        .iter()
        .map(|mb| (mb.name.as_str(), mb.id.as_str()))
        .collect();

    let mut updates: Map<String, Value> = Map::new();
    let mut merges: Vec<(&str, &str, &str, &str)> = Vec::new();

    for (old_name, new_name) in renames {
        let Some(old_id) = by_name.get(old_name.as_str()).copied() else {
            continue;
        };
        match by_name.get(new_name.as_str()).copied() {
            None => {
                updates.insert(old_id.to_string(), json!({ "name": new_name }));
            }
            Some(new_id) if new_id != old_id => {
                merges.push((old_name.as_str(), old_id, new_name.as_str(), new_id));
            }
            Some(_) => {}
        }
    }

    if !updates.is_empty() {
        tracing::info!("Renaming {} mailbox(es) in place (keep emails)...", updates.len());
        let result = client.mailbox_set(None, Some(updates), None, false)?;
        for (mid, err) in &result.not_updated {
            tracing::warn!("Rename failed {mid}: {err}");
        }
    }

    for (old_name, old_id, new_name, new_id) in merges {
        let ids = client.email_query_in(&[old_id.to_string()], None)?;
        tracing::info!("Merging {old_name:?} -> {new_name:?} ({} message(s))", ids.len());
        for chunk in ids.chunks(PAGE) {
            let emails = client.email_get(chunk, &["mailboxIds"])?;
            let mut patch: Map<String, Value> = Map::new();
            for em in &emails {
                let mut mids: HashMap<String, bool> = em.mailbox_ids.clone();
                mids.remove(old_id);
                mids.insert(new_id.to_string(), true);
                patch.insert(em.id.clone(), json!({ "mailboxIds": mids }));
            }
            let res = client.email_set(patch)?;
            for (eid, err) in &res.not_updated {
                tracing::warn!("Merge move failed {eid}: {err}");
            }
        }
        // Only reap once empty; onDestroyRemoveEmails would delete stragglers
        // outright, and losing mail is exactly the failure we are fixing.
        let left = client.email_query_in(&[old_id.to_string()], None)?;
        if !left.is_empty() {
            tracing::warn!("Not destroying {old_name:?}: {} message(s) still present", left.len());
            continue;
        }
        let res = client.mailbox_set(None, None, Some(vec![old_id.to_string()]), false)?;
        for (mid, err) in &res.not_destroyed {
            tracing::warn!("Destroy failed {mid}: {err}");
        }
    }
    Ok(())
}

/// Every mailbox name the rules currently declare, plus the server's own.
fn valid_names(rules: &Rules) -> HashSet<String> {
    let mut valid: HashSet<String> = HashSet::new();
    valid.extend(rules.folders.values().cloned());
    for group in &rules.folder_groups {
        valid.insert(group.name.clone());
        valid.extend(group.children.values().cloned());
    }
    valid.extend(rules.folders_ui.iter().cloned());
    valid.extend(rules.filters.section_headers.iter().cloned());
    valid.extend(rules.filters.views.iter().map(|v| v.folder.clone()));
    valid.extend(SYSTEM_FOLDERS.iter().map(|s| s.to_string()));
    valid
}

/// Delete folders the rules no longer declare, plus duplicates of ones they do.
pub fn cleanup_stale(
    client: &Client,
    rules: &Rules,
    name_to_id: &HashMap<String, String>,
    mailboxes: &[Mailbox],
) -> Result<()> {
    let valid = valid_names(rules);

    // Pass 1: names that aren't current valid ones (true orphans).
    let mut stale: Vec<&Mailbox> = mailboxes
        .iter()
        .filter(|mb| !valid.contains(&mb.name) && mb.role.is_none())
        .collect();

    // Pass 2: valid-name DUPLICATES. `name_to_id` is keyed by name and holds
    // the *canonical* id (the one at the expected parent). Any other mailbox
    // sharing that name is a duplicate — e.g. the post-rename leftover sitting
    // under a legacy parent, which keeps that legacy parent un-destroyable via
    // `mailboxHasChild`. Reaping them here unblocks the parent next poll.
    stale.extend(mailboxes.iter().filter(|mb| {
        valid.contains(&mb.name)
            && mb.role.is_none()
            && name_to_id.get(&mb.name).map(String::as_str) != Some(mb.id.as_str())
    }));

    if stale.is_empty() {
        return Ok(());
    }
    tracing::info!("Found {} stale folders to clean", stale.len());

    // Move emails from stale folders to INBOX first, then delete.
    let inbox_id = find_inbox_id(mailboxes).map(str::to_string);
    for mb in &stale {
        let Some(inbox_id) = &inbox_id else { break };
        let moved = (|| -> Result<()> {
            let eids = client.email_query_in(&[mb.id.clone()], Some(PAGE))?;
            if eids.is_empty() {
                return Ok(());
            }
            let emails = client.email_get(&eids, &["mailboxIds"])?;
            let mut updates: Map<String, Value> = Map::new();
            for em in &emails {
                let mut mids = em.mailbox_ids.clone();
                mids.insert(inbox_id.clone(), true);
                mids.remove(&mb.id);
                updates.insert(em.id.clone(), json!({ "mailboxIds": mids }));
            }
            client.email_set(updates)?;
            Ok(())
        })();
        if let Err(e) = moved {
            tracing::warn!("Error moving emails from {}: {e}", mb.name);
        }
    }

    // Depth from the FULL mailbox list so we delete deepest-first. A stale
    // parent that still has non-stale children won't destroy until those are
    // reparented to ROOT — `ensure_mailboxes` does that in the same poll, so
    // this just needs to retry across polls until the children move.
    let mut by_parent: HashMap<Option<&str>, Vec<&str>> = HashMap::new();
    for mb in mailboxes {
        by_parent.entry(mb.parent_id.as_deref()).or_default().push(&mb.id);
    }
    fn depth<'a>(
        id: &'a str,
        by_parent: &HashMap<Option<&'a str>, Vec<&'a str>>,
        seen: &mut HashSet<&'a str>,
    ) -> usize {
        if !seen.insert(id) {
            return 0;
        }
        let kids = by_parent.get(&Some(id)).map(Vec::as_slice).unwrap_or(&[]);
        1 + kids.iter().map(|k| depth(k, by_parent, seen)).max().unwrap_or(0)
    }

    let mut ordered: Vec<(&Mailbox, usize)> = stale
        .iter()
        .map(|mb| (*mb, depth(&mb.id, &by_parent, &mut HashSet::new())))
        .collect();
    ordered.sort_by_key(|(_, d)| std::cmp::Reverse(*d));

    for (mb, _) in ordered {
        // Two-phase: try the polite destroy; on `mailboxHasEmail` retry with
        // onDestroyRemoveEmails. Only the email flag is JMAP-standard — if a
        // child relationship is the blocker we surface it and let the next
        // poll pick it up after `ensure_mailboxes` reparents.
        let result = match client.mailbox_set(None, None, Some(vec![mb.id.clone()]), false) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("Destroy call failed for {}: {e}", mb.name);
                continue;
            }
        };
        if result.destroyed.iter().any(|d| d == &mb.id) {
            tracing::info!("Deleted stale: {}", mb.name);
            continue;
        }
        let Some(err) = result.not_destroyed.get(&mb.id) else {
            // No success entry AND no failure entry — surface the oddly-shaped
            // response rather than silently dropping it (the prior bug).
            tracing::warn!("Destroy returned no status for {}: {:?}", mb.name, result);
            continue;
        };
        let reason = err.get("type").and_then(Value::as_str).unwrap_or("").to_string();
        if reason == "mailboxHasEmail" || reason == "tooManyEmails" {
            match client.mailbox_set(None, None, Some(vec![mb.id.clone()]), true) {
                Ok(retry) if retry.destroyed.iter().any(|d| d == &mb.id) => {
                    tracing::info!("Deleted stale (force-empty): {}", mb.name);
                }
                Ok(retry) => {
                    tracing::warn!("Force-destroy failed for {}: {:?}", mb.name, retry.not_destroyed);
                }
                Err(e) => tracing::warn!("Force-destroy call failed for {}: {e}", mb.name),
            }
        } else {
            // `mailboxHasChild` / unknown — leave for next poll once
            // ensure_mailboxes has reparented the valid children to ROOT.
            let shown = if reason.is_empty() { err.to_string() } else { reason };
            tracing::info!("Skipping {} for now: {shown} (will retry next poll)", mb.name);
        }
    }
    Ok(())
}
