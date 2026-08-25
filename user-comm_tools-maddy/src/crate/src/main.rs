//! maddy-sorter — the Rust equivalent of Stalwart's jmap-sorter, but for
//! Maddy's IMAP/SQLite backend.
//!
//! Runs `apply-rules` on a fixed interval for the container's lifetime,
//! started by init.sh alongside `maddy run`. Replaces both the external
//! Dagu DAG that used to ssh in every 2 minutes (see this repo's git log
//! for the incident that caused: a hung ssh call let two apply-rules
//! processes run at once and livelock SQLite) AND the bash
//! `cmd_apply_rules` in mail-sieve-subset-post-hoc.sh, which is now dead
//! code kept only for reference during the transition (mail-rules.nix
//! target: remove once this has soaked).
//!
//! Every message the config's `filters.views` (axis="sender") predicates
//! describe stays fully data-driven from /data/mail-rules.json — nothing
//! about WHICH domain routes WHERE is hardcoded here, same as the
//! Stalwart crate. What IS hardcoded: JMAP/IMAP protocol literals
//! (`\Seen`) and this engine's own internal bookkeeping keyword
//! (`$distributed`) — neither is "rules data", both are implementation
//! detail, same category as Stalwart's hardcoded `$sorted`/`$seen`.

mod db;
mod email;
mod rules;

use anyhow::Result;
use rules::Rules;
use std::time::Duration;

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn one_run(db_path: &str, rules_path: &str, rules: &Rules) -> Result<()> {
    let mut conn = db::open(db_path)?;
    let user_id = db::find_user_id(&conn, &rules.account)?;
    let inbox_id = db::find_mailbox_id(&conn, user_id, "INBOX")?
        .ok_or_else(|| anyhow::anyhow!("INBOX not found for {}", rules.account))?;
    let fallback_id = db::find_mailbox_id(&conn, user_id, &rules.routing_default)?;

    // Ruleset-change detection: if the rules file changed since the last
    // run, re-open ($distributed cleared) any INBOX message whose only
    // existing category copy is in the fallback folder, so the next scan
    // re-evaluates it against the new rules instead of leaving it
    // permanently fallback-filed under a stale decision.
    let state_path = db::state_file_path(db_path);
    let new_hash = db::ruleset_hash(rules_path)?;
    let old_hash = db::read_state_hash(&state_path);
    if let (Some(old), Some(fb_id)) = (old_hash, fallback_id) {
        if old != new_hash {
            let ids = db::fallback_only_distributed_ids(&conn, inbox_id, fb_id)?;
            if !ids.is_empty() {
                tracing::info!("ruleset changed — re-opening {} fallback-only message(s)", ids.len());
                db::clear_distributed(&conn, inbox_id, &ids)?;
            }
        }
    }

    let candidates = db::undistributed_inbox_rows(&conn, inbox_id)?;
    if candidates.is_empty() {
        db::resync_msgs_count(&conn, user_id)?;
        db::write_state_hash(&state_path, new_hash)?;
        return Ok(());
    }
    tracing::info!("{} undistributed INBOX message(s)", candidates.len());

    let mut plans = Vec::new();
    let mut all_ids = Vec::with_capacity(candidates.len());
    for (msg_id, cached_header) in &candidates {
        all_ids.push(*msg_id);
        let email = match db::parse_email(cached_header) {
            Ok(e) => e,
            Err(e) => {
                tracing::warn!("msgId {msg_id}: cachedHeader unparseable, filing to fallback only: {e:#}");
                continue;
            }
        };
        let folder = rules
            .rules
            .iter()
            .find(|r| email::matches(&email, &r.when))
            .map(|r| r.folder.as_str())
            .unwrap_or(rules.routing_default.as_str());
        plans.push(db::Plan { target_folder: folder.to_string(), src_msg_id: *msg_id });
    }

    db::backup(db_path)?;
    let (copied, skipped) = db::apply_plan(&mut conn, inbox_id, user_id, &plans, &all_ids)?;
    tracing::info!("copied={copied} skipped={skipped} of {} planned", plans.len());

    db::resync_msgs_count(&conn, user_id)?;
    db::write_state_hash(&state_path, new_hash)?;
    Ok(())
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let rules_path = std::env::var("RULES_PATH").unwrap_or_else(|_| "/data/mail-rules.json".into());
    let db_path = std::env::var("IMAPSQL_DB").unwrap_or_else(|_| "/data/imapsql.db".into());
    let poll_interval = Duration::from_secs(env_or("POLL_INTERVAL", 120u64));
    let startup_delay = Duration::from_secs(env_or("STARTUP_DELAY", 30u64));

    // Load and validate BEFORE the startup delay: a malformed rules file
    // is a permanent error, and failing in milliseconds instead of after
    // a 30s sleep makes the crash loop visible to `docker ps` immediately.
    let rules = match Rules::load(&rules_path) {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("{e:#}");
            std::process::exit(1);
        }
    };

    tracing::info!(
        "maddy-sorter starting — delay {}s, poll every {}s, {} sender routes",
        startup_delay.as_secs(),
        poll_interval.as_secs(),
        rules.rules.len()
    );
    std::thread::sleep(startup_delay);

    loop {
        if let Err(e) = one_run(&db_path, &rules_path, &rules) {
            tracing::error!("run failed: {e:#}");
        }
        std::thread::sleep(poll_interval);
    }
}
