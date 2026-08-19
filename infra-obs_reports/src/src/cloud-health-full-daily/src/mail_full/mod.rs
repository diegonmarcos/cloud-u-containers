//! Absorbed from `cloud-mail-health-full` (2026-04-23).
//!
//! 7-Phase Maddy Mail Diagnostic. Callable as a submodule from
//! `cloud-health-full-daily`:
//!
//!   let mr = mail_full::run().await?;
//!   // mr.markdown — rendered cloud_mail_full.md
//!   // mr.results  — structured MailHealthResult
//!
//! Still writes `cloud_mail_full.md` + `cloud_mail_full.json` to cwd for
//! manifest parity.

pub mod checks;
pub mod constants;
pub mod output;
pub mod phases;
pub mod ssh;
pub mod template;
pub mod types;

use anyhow::Result;
use chrono::Utc;
use std::collections::HashMap;
use std::time::Instant;

use types::*;

pub struct MailReport {
    pub markdown: String,
    pub results: MailHealthResult,
}

fn load_bearer_token() -> Option<String> {
    let home = std::env::var("HOME").unwrap_or("/home/diego".into());
    let path = format!("{}/{}", home, constants::BEARER_TOKEN_PATH);
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v["access_token"].as_str().map(|s| s.to_string()))
}

pub async fn run() -> Result<MailReport> {
    let start = Instant::now();
    println!("=== Cloud Mail Full Report (7-Phase Maddy Diagnostic) ===");

    let bearer_token = load_bearer_token();
    println!(
        "Bearer token: {}",
        if bearer_token.is_some() { "loaded" } else { "not found (OIDC checks will fail)" }
    );

    let mut timers: HashMap<String, u64> = HashMap::new();

    // Tier 0: Path checker
    let tp = Instant::now();
    println!("\n  Tier 0: Path Checker...");
    let path_checks = phases::path_checker().await;
    let tp_ms = tp.elapsed().as_millis() as u64;
    timers.insert("T0_path_checker".into(), tp_ms);
    let out_pass = path_checks.iter().filter(|c| c.name.starts_with("OUT") && c.passed).count();
    let out_total = path_checks.iter().filter(|c| c.name.starts_with("OUT")).count();
    let in_pass = path_checks.iter().filter(|c| c.name.starts_with("IN") && c.passed).count();
    let in_total = path_checks.iter().filter(|c| c.name.starts_with("IN")).count();
    println!(
        "  Tier 0: OUTBOUND {}/{} | INBOUND {}/{} in {:.1}s",
        out_pass, out_total, in_pass, in_total, tp_ms as f64 / 1000.0
    );
    for c in &path_checks {
        let icon = if c.passed { "✓" } else { "✗" };
        println!("    {} {} — {}", icon, c.name, c.details);
    }

    // Phase 0
    let t0 = Instant::now();
    println!("\n  Phase 0: Instant KPIs...");
    let instant_kpis = phases::phase0_instant_kpis().await;
    let p0_ms = t0.elapsed().as_millis() as u64;
    timers.insert("P0_instant_kpis".into(), p0_ms);
    println!(
        "  Phase 0: {}/{} in {:.1}s",
        instant_kpis.iter().filter(|c| c.passed).count(),
        instant_kpis.len(),
        p0_ms as f64 / 1000.0
    );

    // Phase 1
    let t1 = Instant::now();
    println!("\n  Phase 1: Pre-flight (3-VM parallel)...");
    let (preflight_checks, mut mail_data, apps_data, proxy_data) = phases::preflight().await;
    let p1_ms = t1.elapsed().as_millis() as u64;
    timers.insert("P1_preflight".into(), p1_ms);
    println!(
        "  Phase 1: {}/{} in {:.1}s (mail={} apps={} proxy={})",
        preflight_checks.iter().filter(|c| c.passed).count(),
        preflight_checks.len(),
        p1_ms as f64 / 1000.0,
        if mail_data.is_some() { "OK" } else { "FAIL" },
        if apps_data.is_some() { "OK" } else { "FAIL" },
        if proxy_data.is_some() { "OK" } else { "FAIL" },
    );

    let ssh_ok = mail_data.is_some();

    // Phases 2-5
    let t_par = Instant::now();
    let containers = if ssh_ok {
        phases::container_health(&mail_data, &apps_data)
    } else {
        vec![Check {
            name: "skipped".into(),
            passed: false,
            details: "SSH unreachable".into(),
            duration_ms: 0,
            error: Some("SSH to oci-mail failed".into()),
            severity: Severity::Critical,
        }]
    };

    let (network, dns_auth_checks) = tokio::join!(
        phases::network_checks(&mail_data, &apps_data, &proxy_data, &bearer_token),
        phases::dns_auth(),
    );

    let internals = if ssh_ok {
        phases::mail_internals(&mail_data)
    } else {
        vec![Check {
            name: "skipped".into(),
            passed: false,
            details: "SSH unreachable".into(),
            duration_ms: 0,
            error: Some("SSH to oci-mail failed".into()),
            severity: Severity::Critical,
        }]
    };

    let par_ms = t_par.elapsed().as_millis() as u64;
    timers.insert("P2-P5_parallel".into(), par_ms);
    println!("\n  Phases 2-5 parallel: {:.1}s", par_ms as f64 / 1000.0);

    // Phase 5b: config drift
    let config_drift = phases::config_drift(&mut mail_data);
    println!(
        "    P5b Config Drift: {}/{}{}",
        config_drift.iter().filter(|c| c.passed).count(),
        config_drift.len(),
        if config_drift.iter().all(|c| c.passed) { " ✓" } else { " ← DRIFT DETECTED" }
    );

    // Phase 6: E2E delivery
    let t6 = Instant::now();
    println!("\n  Phase 6: E2E Delivery...");
    let e2e_delivery = phases::e2e_delivery(&mail_data).await;
    let p6_ms = t6.elapsed().as_millis() as u64;
    timers.insert("P6_e2e_delivery".into(), p6_ms);
    println!(
        "  Phase 6: {}/{} in {:.1}s",
        e2e_delivery.iter().filter(|c| c.passed).count(),
        e2e_delivery.len(),
        p6_ms as f64 / 1000.0
    );

    // Build results
    let total_ms = start.elapsed().as_millis() as u64;
    timers.insert("TOTAL".into(), total_ms);

    let all_checks: Vec<&Check> = path_checks
        .iter()
        .chain(&instant_kpis)
        .chain(&preflight_checks)
        .chain(&containers)
        .chain(&network)
        .chain(&dns_auth_checks)
        .chain(&internals)
        .chain(&config_drift)
        .chain(&e2e_delivery)
        .collect();

    let total_count = all_checks.len();
    let passed_count = all_checks.iter().filter(|c| c.passed).count();
    let failed_count = total_count - passed_count;
    let critical_count = all_checks
        .iter()
        .filter(|c| !c.passed && c.severity == Severity::Critical)
        .count();
    let warning_count = all_checks
        .iter()
        .filter(|c| !c.passed && c.severity == Severity::Warning)
        .count();

    let results = MailHealthResult {
        generated: Utc::now().to_rfc3339(),
        duration_ms: total_ms,
        path_checks,
        instant_kpis,
        preflight: preflight_checks,
        containers,
        network,
        dns_auth: dns_auth_checks,
        internals,
        config_drift,
        e2e_delivery,
        summary: Summary {
            total_checks: total_count,
            passed: passed_count,
            failed: failed_count,
            warnings: warning_count,
            critical: critical_count,
        },
        timers,
    };

    // Render in-memory only — NO disk writes.
    // The standalone `cloud-mail-health-full` derive crate owns the
    // `cloud_mail_full.md` / `cloud_mail_full.json` artefacts. This submodule
    // is the in-process path that feeds daily's Z-appendix.
    let vars = output::build_template_vars(&results);
    let md = template::render_string(&vars)?;

    println!(
        "\n=== mail_full done in {:.1}s === {}/{} passed, {} critical, {} warnings (in-memory, no disk write)",
        total_ms as f64 / 1000.0,
        passed_count,
        total_count,
        critical_count,
        warning_count,
    );

    Ok(MailReport {
        markdown: md,
        results,
    })
}
