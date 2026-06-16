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
                loop {
                    let res = imap_loop::run(
                        &src_clone,
                        &mbox,
                        &cfg_clone,
                        state_clone.clone(),
                    ).await;
                    match res {
                        Ok(()) => tracing::warn!(source = %src_clone.id, mailbox = %mbox, "loop returned Ok; restarting"),
                        Err(e)  => tracing::error!(source = %src_clone.id, mailbox = %mbox, error = %e, "loop crashed; backing off"),
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(
                        cfg_clone.defaults.reconnect_backoff_secs.first().copied().unwrap_or(5)
                    )).await;
                }
            }));
        }
    }

    // Graceful SIGTERM / SIGINT shutdown.
    tokio::signal::ctrl_c().await?;
    tracing::info!("SIGINT — shutting down");
    Ok(())
}
