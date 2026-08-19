//! Stack report — topology / resources / databases / storage / security sections.
//! Absorbed from former cloud-stack-report crate (2026-04-20), now part of
//! `cloud-health-full-daily::health_full2`.

pub mod checks;
pub mod collectors;
pub mod parsers;
pub mod sections;
pub mod template;
pub mod types;

use anyhow::Result;

/// Run the stack pipeline. Returns `(rendered_markdown, live_data_json)`.
/// In-memory only — parent daily binary owns the consolidated artefact.
pub async fn run() -> Result<(String, serde_json::Value)> {
    eprintln!("[stack] collecting topology + live data");
    let ctx = parsers::load_context()?;
    eprintln!(
        "[stack] loaded: {} VMs, {} URLs, {} DNS, {} DBs",
        ctx.vms.len(),
        ctx.public_urls.len(),
        ctx.private_dns.len(),
        ctx.databases.len()
    );
    let live = collectors::collect_all(&ctx).await;
    let vars = sections::build_all_vars(&ctx, &live);
    let md = template::render_string(&vars)?;
    let json_value = serde_json::to_value(&live)?;
    Ok((md, json_value))
}
