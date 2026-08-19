//! Phase 3 render-only mode — re-renders the daily HTML/MD/JSON from the
//! Pass-1 ReportData on disk, enriched with derive contributions written
//! into the run-state snapshot (Phase 2).
//!
//! Trigger: `REPORTS_RENDER_ONLY=1`. The master is invoked a second time
//! after the parallel derive fan-out, so the appendix Z-sections covering
//! the mail derive (and later url / sec-network) are populated from the
//! derives' on-disk markdown rather than re-collected in-process.
//!
//! Why we read from disk rather than re-deserialising every section out of
//! the JSON snapshot: the appendix parser already takes markdown blobs and
//! re-numbers them into Z.N sections — exactly the artefacts the derives
//! drop into cwd. Reading typed slices out of the snapshot would force a
//! cross-crate type-import dance that the plan defers as Step 10.

use crate::appendix::{self, Appendix};
use crate::types::ReportData;
use crate::{html, md};
use anyhow::{Context, Result};
use reports_common::run_state::{RunState, RUN_STATE_FILENAME};
use std::path::Path;

/// Output filename master writes for its own ReportData (also used as
/// programmatic-access JSON in default mode). Render-only re-reads this.
const REPORT_DATA_PATH: &str = "cloud_health_daily.json";

pub async fn run() -> Result<()> {
    println!("=== Cloud Health Daily — RENDER-ONLY (Phase 3) ===");

    // 1. Load Pass-1 ReportData. Without it we have nothing to render —
    //    fail loud rather than silently producing an empty page.
    let raw = std::fs::read(REPORT_DATA_PATH)
        .with_context(|| format!("read {}", REPORT_DATA_PATH))?;
    let mut report: ReportData = serde_json::from_slice(&raw)
        .with_context(|| format!("parse {}", REPORT_DATA_PATH))?;

    // 2. Load the run-state snapshot (best-effort — derives might have all
    //    failed). Used today only for the trace banner; future steps will
    //    materialise typed slices out of it.
    let snapshot_path = Path::new(RUN_STATE_FILENAME);
    let snapshot: Option<RunState> = match RunState::load(snapshot_path) {
        Ok(rs) => Some(rs),
        Err(e) => {
            eprintln!("[render_only] no usable snapshot: {e}");
            None
        }
    };

    // 3. Read derive markdown artefacts. The mail derive always writes
    //    `cloud_mail_full.md`. `cloud_health_full.md` is the legacy stack
    //    sub-engine output — defensive: present in older builds, absent in
    //    the new world.
    let mail_md = std::fs::read_to_string("cloud_mail_full.md").unwrap_or_default();
    let full_md = std::fs::read_to_string("cloud_health_full.md").unwrap_or_default();

    // 4. Build a fresh appendix from those artefacts. `from_reports` would
    //    require the in-process FullReport / MailReport structs we no
    //    longer build in Phase 1, so we drive the parser directly from the
    //    markdown using `Appendix::from_markdown`.
    let apx = Appendix::from_markdown(&full_md, &mail_md);
    println!(
        "Appendix from disk: {} (snapshot={})",
        apx.summary(),
        if snapshot.is_some() { "loaded" } else { "missing" }
    );

    // 5. Patch the appendix fields and re-render. mail_health is left
    //    untouched: html.rs already falls back to VM mail_queue stats when
    //    mail_health is None, and the appendix Z-sections carry the
    //    rich mail content from the derive.
    report.appendix_md = apx.legacy_md();
    report.appendix_full = apx.full.clone();
    report.appendix_stack = apx.stack.clone();

    // 6. Render HTML (email + web), MD, JSON. Overwrites Pass-1 outputs.
    let html_email = html::render(&report, html::OutputMode::Email);
    let html_web = html::render(&report, html::OutputMode::Web);
    let md_out = match md::render(&report) {
        Ok(s) => Some(s),
        Err(e) => {
            eprintln!("[md] render failed in render-only mode: {e}");
            None
        }
    };

    std::fs::write("cloud_health_daily.html", &html_email)?;
    std::fs::write("cloud_health_daily_web.html", &html_web)?;
    if let Some(ref md_s) = md_out {
        std::fs::write(md::output_path(), md_s)?;
    }
    std::fs::write(REPORT_DATA_PATH, serde_json::to_string_pretty(&report)?)?;

    println!(
        "=== RENDER-ONLY DONE === HTML: {} bytes email, {} bytes web{}",
        html_email.len(),
        html_web.len(),
        md_out
            .as_ref()
            .map(|s| format!(", MD: {} bytes", s.len()))
            .unwrap_or_default(),
    );

    Ok(())
}
