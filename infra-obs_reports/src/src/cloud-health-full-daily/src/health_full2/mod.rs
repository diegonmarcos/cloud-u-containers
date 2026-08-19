//! Absorbed from `cloud-health-full-2` (2026-04-23).
//!
//! 11-Layer Diagnostic + Stack sub-engine. Callable as a submodule from
//! `cloud-health-full-daily`:
//!
//!   let report = health_full2::run().await?;
//!   // report.markdown  — concatenated 11-layer + stack markdown
//!   // report.results   — structured LayerResults for programmatic access
//!   // report.stack     — LiveData from stack sub-engine
//!
//! Still writes `cloud_health_full.md`, `cloud_health_full.json`,
//! `cloud_stack.json` to cwd for manifest parity.

pub mod checks;
pub mod context;
pub mod layers;
pub mod output;
pub mod ssh;
pub mod stack;
pub mod template;
pub mod types;

use anyhow::Result;
use chrono::Utc;
use std::collections::HashMap;
use std::time::Instant;

use types::*;

pub struct FullReport {
    /// Concatenated 11-layer markdown + stack markdown (same content written to disk).
    pub markdown: String,
    pub results: LayerResults,
    /// Live data from stack sub-engine (also written to `cloud_stack.json`).
    pub stack: Option<serde_json::Value>,
}

pub async fn run(
    fleet: Option<&reports_common::fleet::FleetState>,
) -> Result<FullReport> {
    let start = Instant::now();
    println!("=== Cloud Health Full Report (11-Layer) ===");

    let ctx = context::load_context()?;
    println!(
        "Loaded: {} VMs, {} services, {} caddy routes, {} build.json ports",
        ctx.vms.len(),
        ctx.services.len(),
        ctx.caddy_route_list.len(),
        ctx.service_ports.len()
    );

    let mut timers: HashMap<String, u64> = HashMap::new();

    // Sequential: L1 → L2 → L3
    let t1 = Instant::now();
    let self_check = layers::layer_self_check(&ctx).await;
    let l1_ms = t1.elapsed().as_millis() as u64;
    timers.insert("L1_self_check".into(), l1_ms);
    println!(
        "  L1 Self-check: {}/{} in {:.1}s",
        self_check.iter().filter(|c| c.passed).count(),
        self_check.len(),
        l1_ms as f64 / 1000.0
    );

    let t2 = Instant::now();
    let (wg_mesh, reachable_vms) = layers::layer_wg_mesh(&ctx, fleet).await;
    let l2_ms = t2.elapsed().as_millis() as u64;
    timers.insert("L2_wg_mesh".into(), l2_ms);
    println!(
        "  L2 WG Mesh: {}/{} reachable in {:.1}s",
        reachable_vms.len(),
        ctx.vms.len(),
        l2_ms as f64 / 1000.0
    );

    let t3 = Instant::now();
    let (platform, vm_batch, ssh_ok_vms, docker_ok_vms) =
        layers::layer_platform(&ctx, &reachable_vms).await;
    let l3_ms = t3.elapsed().as_millis() as u64;
    timers.insert("L3_platform".into(), l3_ms);
    println!(
        "  L3 Platform: ssh={}/{} docker={}/{} in {:.1}s",
        ssh_ok_vms.len(),
        ctx.vms.len(),
        docker_ok_vms.len(),
        ctx.vms.len(),
        l3_ms as f64 / 1000.0
    );

    // Parallel: L4-L11
    let t_par = Instant::now();
    let containers = layers::layer_containers(&ctx, &vm_batch);
    let (public_urls, private_urls, external, security, email_e2e) = tokio::join!(
        layers::layer_public_urls(&ctx),
        layers::layer_private_urls(&ctx),
        layers::layer_external(&ctx),
        layers::layer_security(&ctx),
        layers::layer_email_e2e(&ctx, &reachable_vms),
    );
    let cross_checks =
        layers::layer_cross_checks(&ctx, &vm_batch, &public_urls, &private_urls, &containers);
    let drift = layers::layer_drift(&ctx, &vm_batch);
    let par_ms = t_par.elapsed().as_millis() as u64;
    timers.insert("L4-L11_parallel".into(), par_ms);
    println!("  L4-L11 parallel: {:.1}s", par_ms as f64 / 1000.0);

    let total_ms = start.elapsed().as_millis() as u64;
    timers.insert("TOTAL".into(), total_ms);

    let all_checks: Vec<&Check> = self_check
        .iter()
        .chain(&wg_mesh)
        .chain(&platform)
        .chain(&containers)
        .chain(&private_urls)
        .chain(&public_urls)
        .chain(&cross_checks)
        .chain(&external)
        .chain(&drift)
        .chain(&security)
        .chain(&email_e2e)
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

    let results = LayerResults {
        generated: Utc::now().to_rfc3339(),
        duration_ms: total_ms,
        self_check,
        wg_mesh,
        platform,
        containers,
        public_urls,
        private_urls,
        cross_checks,
        external,
        drift,
        security,
        email_e2e,
        summary: Summary {
            total_checks: total_count,
            passed: passed_count,
            failed: failed_count,
            warnings: warning_count,
            critical: critical_count,
        },
        timers,
    };

    // Render 11-layer markdown, then append stack output.
    // We DO NOT write cloud_health_full.md / cloud_health_full.json /
    // cloud_stack.json to disk any more — this submodule's output is
    // consolidated into cloud_health_daily.* by the parent binary.
    let vars = output::build_template_vars(&results);
    let mut combined_md = template::render_string(&vars)?;
    let stack_value = match stack::run().await {
        Ok((stack_md, stack_json)) => {
            combined_md.push_str("\n\n---\n\n");
            combined_md.push_str(&stack_md);
            Some(stack_json)
        }
        Err(e) => {
            eprintln!("[health_full2::stack] FAILED: {}", e);
            None
        }
    };

    println!(
        "\n=== health_full2 done in {:.1}s === {}/{} passed, {} critical, {} warnings (in-memory, no disk write)",
        total_ms as f64 / 1000.0,
        passed_count,
        total_count,
        critical_count,
        warning_count,
    );

    Ok(FullReport {
        markdown: combined_md,
        results,
        stack: stack_value,
    })
}
