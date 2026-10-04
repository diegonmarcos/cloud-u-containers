//! cloud-url-health-report — fast E2E probe: public URLs + private URLs + email round-trip.
//! Target: under 15 seconds wall-clock.

mod config;
mod private_checks;
mod public_checks;
mod template;

use reports_common::email_e2e;

use anyhow::Result;
use chrono::Utc;
use serde::Serialize;
use std::collections::HashMap;
use std::time::Instant;

#[derive(Debug, Serialize)]
struct Report {
    generated: String,
    duration_ms: u64,
    summary: Summary,
    public: Vec<public_checks::PublicResult>,
    private: Vec<private_checks::PrivateResult>,
    email: email_e2e::EmailResult,
}

#[derive(Debug, Serialize, Default)]
struct Summary {
    public_total: usize,
    public_ok: usize,
    private_total: usize,
    private_ok: usize,
    email_outbound_ok: bool,
    email_inbound_ok: bool,
    total_ms: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    let start = Instant::now();
    println!("=== cloud-url-health (fast E2E) ===");

    let cfg = config::load()?;
    let public_targets = public_checks::load_public_targets();
    let private_targets = private_checks::load_private_targets();
    let bearer = reports_common::context::load_bearer_token();

    println!(
        "Targets: {} public, {} private  | bearer={}",
        public_targets.len(),
        private_targets.len(),
        if bearer.is_some() { "present" } else { "absent" },
    );

    let token = format!("url-e2e-{}", uuid::Uuid::new_v4());

    let join_t = Instant::now();
    let (public_results, private_results, email_result) = tokio::join!(
        public_checks::run(
            public_targets,
            bearer.as_deref(),
            cfg.concurrency.public,
            &cfg.timeouts,
            &cfg.targets.fallback_body_markers,
        ),
        private_checks::run(
            private_targets,
            bearer.as_deref(),
            cfg.concurrency.private,
            &cfg.timeouts,
            &cfg.targets.tcp_only_ports,
        ),
        email_e2e::run(&cfg.email, &token),
    );
    println!(
        "⏱  public+private+email parallel: {:.1}s",
        join_t.elapsed().as_secs_f64()
    );

    let summary = Summary {
        public_total: public_results.len(),
        public_ok: public_results.iter().filter(|r| r.ok).count(),
        private_total: private_results.len(),
        private_ok: private_results.iter().filter(|r| r.ok).count(),
        email_outbound_ok: email_result.outbound_ok,
        email_inbound_ok: email_result.inbound_ok,
        total_ms: start.elapsed().as_millis() as u64,
    };

    let report = Report {
        generated: Utc::now().to_rfc3339(),
        duration_ms: summary.total_ms,
        summary,
        public: public_results,
        private: private_results,
        email: email_result,
    };

    let vars = build_vars(&report);
    let md = template::render_string(&vars)?;
    std::fs::write("cloud_url_health.md", &md)?;
    println!("Wrote cloud_url_health.md");

    let json = serde_json::to_string_pretty(&report)?;
    std::fs::write("cloud_url_health.json", &json)?;
    println!("Wrote cloud_url_health.json");

    // Merge into shared run-state snapshot for master appendix re-render.
    {
        use reports_common::run_state::{RunState, RUN_STATE_FILENAME};
        let path = std::path::PathBuf::from(RUN_STATE_FILENAME);
        match serde_json::to_value(&report) {
            Ok(v) => {
                if let Err(e) = RunState::merge_section(&path, |s| s.url_health = Some(v)) {
                    eprintln!("[run_state] url-derive merge failed: {e}");
                } else {
                    println!("[run_state] merged url_health slice into {}", path.display());
                }
            }
            Err(e) => eprintln!("[run_state] url-derive serialise failed: {e}"),
        }
    }

    println!(
        "=== DONE in {:.1}s === public={}/{} private={}/{} email_out={} email_in={}",
        report.duration_ms as f64 / 1000.0,
        report.summary.public_ok,
        report.summary.public_total,
        report.summary.private_ok,
        report.summary.private_total,
        report.summary.email_outbound_ok,
        report.summary.email_inbound_ok,
    );

    Ok(())
}

fn build_vars(r: &Report) -> HashMap<String, String> {
    let mut v = HashMap::new();
    v.insert("GENERATED_DATE".into(), r.generated.clone());
    v.insert(
        "TOTAL_DURATION".into(),
        format!("{:.1}s", r.duration_ms as f64 / 1000.0),
    );
    v.insert(
        "PUBLIC_COUNT".into(),
        format!("{}/{}", r.summary.public_ok, r.summary.public_total),
    );
    v.insert(
        "PRIVATE_COUNT".into(),
        format!("{}/{}", r.summary.private_ok, r.summary.private_total),
    );
    v.insert(
        "EMAIL_STATUS".into(),
        format!(
            "outbound={} inbound={}",
            if r.summary.email_outbound_ok { "✅" } else { "❌" },
            if r.summary.email_inbound_ok { "✅" } else { "❌" },
        ),
    );

    v.insert("PUBLIC_TABLE".into(), render_public_table(&r.public));
    v.insert("PRIVATE_TABLE".into(), render_private_table(&r.private));
    v.insert("EMAIL_RESULT".into(), render_email(&r.email));
    v
}

fn render_public_table(rows: &[public_checks::PublicResult]) -> String {
    let mut out = String::new();
    out.push_str("| URL | Upstream | Category | Status | Latency | OK | Error |\n");
    out.push_str("|---|---|---|---|---|---|---|\n");
    for r in rows {
        out.push_str(&format!(
            "| {} | {} | {} | {} | {}ms | {} | {} |\n",
            r.url,
            r.upstream,
            r.category,
            r.status.map(|s| s.to_string()).unwrap_or_else(|| "-".into()),
            r.latency_ms,
            if r.ok { "✅" } else { "❌" },
            r.error.as_deref().unwrap_or(""),
        ));
    }
    out
}

fn render_private_table(rows: &[private_checks::PrivateResult]) -> String {
    let mut out = String::new();
    out.push_str("| Service | Upstream | Source | Probe | Status | Latency | OK | Error |\n");
    out.push_str("|---|---|---|---|---|---|---|---|\n");
    for r in rows {
        out.push_str(&format!(
            "| {} | {} | {} | {} | {} | {}ms | {} | {} |\n",
            r.service,
            r.upstream,
            r.source,
            r.probe,
            r.status.map(|s| s.to_string()).unwrap_or_else(|| "-".into()),
            r.latency_ms,
            if r.ok { "✅" } else { "❌" },
            r.error.as_deref().unwrap_or(""),
        ));
    }
    out
}

fn render_email(e: &email_e2e::EmailResult) -> String {
    let tick = |b: bool| if b { "✅" } else { "❌" };
    let mut out = String::new();
    out.push_str(&format!("- **Subject**: `{}`\n", e.subject));
    out.push_str(&format!("- **Health (all legs)**: {}\n", tick(e.all_ok())));
    out.push_str(&format!(
        "- **Outbound (SMTP→Maddy)**: {} ({} ms)\n",
        tick(e.outbound_ok),
        e.outbound_ms
    ));
    out.push_str(&format!(
        "- **Land · IMAP (Maddy)**:  {} ({} ms)\n",
        tick(e.inbound_ok),
        e.inbound_ms
    ));
    if e.jmap_checked {
        out.push_str(&format!(
            "- **Land · JMAP (Stalwart)**: {} ({} ms)\n",
            tick(e.jmap_ok),
            e.jmap_ms
        ));
    }
    if e.api_checked {
        out.push_str(&format!("- **mail-API liveness**: {}\n", tick(e.api_ok)));
    }
    if e.mcp_checked {
        out.push_str(&format!("- **mail-MCP liveness**: {}\n", tick(e.mcp_ok)));
    }
    if let Some(err) = &e.error {
        out.push_str(&format!("- **Error**: {}\n", err));
    }
    out
}
