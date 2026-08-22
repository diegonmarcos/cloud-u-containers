//! mail-puller — IMAP-IDLE sidecar.
//!
//! Each entry in sources.json becomes one tokio task.
//! Per task: OAuth2 refresh → IMAPS connect → SELECT mailbox → IDLE loop.
//! New messages fetched by UID, then dual-delivered via SMTP to every target
//! listed in the source's `targets`. Local SMTP = normal delivery pipeline on
//! Maddy (filter + sort) and Stalwart (Sieve) applies, so pulled mail lands in
//! the right emoji/category folder alongside native incoming mail.
//!
//! State DB (sqlite, single file) stores last-seen UIDVALIDITY + UID per
//! (source, mailbox) so restarts don't re-fetch and don't miss.

mod config;
mod oauth;
mod imap_loop;
mod deliver;
mod state;

use futures::FutureExt;
use std::panic::AssertUnwindSafe;
use anyhow::Result;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new("mail_puller=info")))
        .init();

    let cfg = config::load()?;
    tracing::info!(
        sources = cfg.sources.len(),
        targets = cfg.delivery_targets.len(),
        "mail-puller bootstrapped"
    );

    let state = state::State::open(&cfg.state_db)?;

    // One long-running task per (source × mailbox). IDLE keeps each task
    // on a persistent connection; panics bubble up and the task restarts.
    let mut handles = Vec::new();
    for src in cfg.sources.clone() {
        for mbox in src.mailboxes.clone() {
            let src_clone = src.clone();
            let cfg_clone = cfg.clone();
            let state_clone = state.clone();
            handles.push(tokio::spawn(async move {
                let backoffs: Vec<u64> = if cfg_clone.defaults.reconnect_backoff_secs.is_empty() {
                    vec![5]
                } else {
                    cfg_clone.defaults.reconnect_backoff_secs.clone()
                };
                let mut attempt: usize = 0;
                loop {
                    let started = std::time::Instant::now();
                    // ponytail: catch_unwind because the JoinHandles are never awaited — a
                    // panic used to kill a source silently, which is exactly how gmail-primary
                    // went dark for two days while the other source kept logging.
                    let res = AssertUnwindSafe(imap_loop::run(
                        &src_clone,
                        &mbox,
                        &cfg_clone,
                        state_clone.clone(),
                    )).catch_unwind().await;
                    match res {
                        Ok(Ok(())) => tracing::warn!(source = %src_clone.id, mailbox = %mbox, "loop returned Ok; restarting"),
                        Ok(Err(e)) => {
                            let chain = format!("{:#}", e);
                            tracing::error!(source = %src_clone.id, mailbox = %mbox, error = %chain, "loop crashed; backing off");
                        }
                        Err(_) => tracing::error!(source = %src_clone.id, mailbox = %mbox, "loop PANICKED; backing off"),
                    }
                    // Escalate through the configured backoff ladder instead of always
                    // reusing the first entry — a fixed 5s retry is what earned us Gmail's
                    // "Too many simultaneous connections". Reset once a run has held for a
                    // few minutes, so a transient failure doesn't pin us at max forever.
                    if started.elapsed() >= std::time::Duration::from_secs(300) {
                        attempt = 0;
                    }
                    let secs = backoffs[attempt.min(backoffs.len() - 1)];
                    attempt = attempt.saturating_add(1);
                    tracing::info!(source = %src_clone.id, mailbox = %mbox, backoff_secs = secs, "restarting source");
                    tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
                }
            }));
        }
    }

    // Graceful SIGTERM / SIGINT shutdown.
    tokio::signal::ctrl_c().await?;
    tracing::info!("SIGINT — shutting down");
    Ok(())
}
