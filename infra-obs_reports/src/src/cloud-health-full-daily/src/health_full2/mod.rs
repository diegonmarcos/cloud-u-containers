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
use std::future::Future;
use std::time::{Duration, Instant};

use types::*;

/// Per-layer deadline for the L5–L10 probes in the `tokio::join!` below.
///
/// Derived, not chosen: across the 23 archived green reports that carry
/// `timers` (cloud-data `y_old/reports/dist/cloud_health_daily.json` +
/// the retired `reports/cloud-health-full-report/cloud_health_full.json`),
/// `L4-L11_parallel` ran min 24.7s / median 27.9s / max 48.2s. Since those
/// five layers run concurrently, that 48.2s worst case upper-bounds any ONE
/// of them. Independently, the worst-case *sequential* sum of the deadlines a
/// single layer can legitimately spend is L10 security: 3× `dns_txt` @5s +
/// 2× `http_get` @8s + `tcp_scan` @3s + 4 VMs × 2 `tcp` @3s = 58s.
/// 90s clears both (1.9× the measured worst, 1.6× the theoretical worst) and
/// still leaves the whole report far inside the 20-minute step `timeout` that
/// cloud-health.yml wraps the container in.
const LAYER_DEADLINE: Duration = Duration::from_secs(90);

/// L11 does not share `LAYER_DEADLINE`. It is the only layer that waits on a
/// third party (SMTP → IMAP/JMAP round-trip), and its legitimate runtime is
/// measured in minutes, not seconds. Its budget is the mail round-trip timeout
/// that is ALREADY declared as data — `build-reports.json:.url_health.email
/// .timeout_secs` (180s today) — plus this margin for the SMTP send and the
/// mail-API / mail-MCP liveness and Maddy-SSH legs that bracket the poll.
/// Reading the declared value rather than restating it means raising the poll
/// timeout cannot silently start guillotining the layer that owns it.
const EMAIL_LAYER_MARGIN: Duration = Duration::from_secs(90);

/// Used only when `email_e2e::load_config()` fails outright (no
/// build-reports.json, no legacy fallback). Mirrors the declared value so a
/// config-read failure cannot shrink the budget below the real round-trip.
const EMAIL_ROUNDTRIP_FALLBACK: Duration = Duration::from_secs(180);

/// Run one L5–L11 layer under its OWN deadline.
///
/// `tokio::join!` waits for ALL of its futures, and before this existed not one
/// of the five had a deadline: a single wedged probe hung the entire health
/// report forever with no output and no error. Run 35022084038 sat 3h43m
/// between the L3 line and the L4-L11 line and had to be cancelled by hand;
/// run 35041138252 reproduced it and was killed at 20 minutes by the step-level
/// `timeout`, its log showing L11 (`[email_e2e]`) still polling 441s into a
/// 180s budget.
///
/// The deadline is deliberately PER LAYER and not one timeout around the whole
/// `join!`: one deadline around the join tells you the report hung but not
/// WHICH layer hung, which is how this defect survived two investigations.
///
/// A layer that blows its deadline does NOT return an empty `Vec<Check>`. An
/// empty vec reads downstream as "this layer found zero problems" — a health
/// reporter that goes quiet when a probe wedges is the exact failure being
/// fixed here. It returns one FAILED `Critical` check naming the layer, so the
/// timeout is counted in `summary.critical`, shows up in the rendered report,
/// and trips the Dagu DAG's `critical != 0` ntfy alarm.
async fn with_deadline(
    layer: &str,
    budget: Duration,
    fut: impl Future<Output = Vec<Check>>,
) -> Vec<Check> {
    let t = Instant::now();
    match tokio::time::timeout(budget, fut).await {
        Ok(checks) => {
            println!(
                "    {}: {} checks in {:.1}s",
                layer,
                checks.len(),
                t.elapsed().as_secs_f64()
            );
            checks
        }
        Err(_) => {
            eprintln!(
                "::error::health_full2: LAYER {} EXCEEDED ITS {:.1}s DEADLINE — a probe inside it wedged. Its checks are MISSING from this report, not passing.",
                layer,
                budget.as_secs_f64()
            );
            vec![Check {
                name: format!("LAYER TIMEOUT: {}", layer),
                passed: false,
                details: format!(
                    "layer {} did not finish within {:.1}s — a probe inside it wedged. Every check this layer would have produced is MISSING from this report; do NOT read their absence as healthy.",
                    layer,
                    budget.as_secs_f64()
                ),
                duration_ms: t.elapsed().as_millis() as u64,
                error: Some(format!("layer deadline exceeded after {:.1}s", budget.as_secs_f64())),
                severity: Severity::Critical,
            }]
        }
    }
}

/// Wall-clock a SYNCHRONOUS layer.
///
/// L4/L7/L9 are plain functions, not futures, so `tokio::time::timeout` cannot
/// cover them — and they sit in the same mod.rs:93..107 window that the hang was
/// localised to. Printing their elapsed time means a future wedge in a sync
/// layer is narrowed to one named layer instead of being invisible between two
/// prints, which is the whole reason this defect took two rounds to place.
fn timed<T>(layer: &str, f: impl FnOnce() -> T) -> T {
    let t = Instant::now();
    let out = f();
    println!("    {}: in {:.1}s", layer, t.elapsed().as_secs_f64());
    out
}

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

    // Parallel: L4-L11 — every layer under its own deadline (see with_deadline).
    let t_par = Instant::now();
    let containers = timed("L4 containers", || layers::layer_containers(&ctx, &vm_batch));

    let email_budget = reports_common::email_e2e::load_config()
        .map(|c| Duration::from_secs(c.timeout_secs))
        .unwrap_or(EMAIL_ROUNDTRIP_FALLBACK)
        + EMAIL_LAYER_MARGIN;

    let (public_urls, private_urls, external, security, email_e2e) = tokio::join!(
        with_deadline("L5 public_urls", LAYER_DEADLINE, layers::layer_public_urls(&ctx)),
        with_deadline("L6 private_urls", LAYER_DEADLINE, layers::layer_private_urls(&ctx)),
        with_deadline("L8 external", LAYER_DEADLINE, layers::layer_external(&ctx)),
        with_deadline("L10 security", LAYER_DEADLINE, layers::layer_security(&ctx)),
        with_deadline(
            "L11 email_e2e",
            email_budget,
            layers::layer_email_e2e(&ctx, &reachable_vms),
        ),
    );
    let cross_checks = timed("L7 cross_checks", || {
        layers::layer_cross_checks(&ctx, &vm_batch, &public_urls, &private_urls, &containers)
    });
    let drift = timed("L9 drift", || layers::layer_drift(&ctx, &vm_batch));
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// A future that never resolves — stands in for the wedged probe.
    /// This is exactly what `poll_once` did for 441s inside run 35041138252.
    async fn never() -> Vec<Check> {
        futures::future::pending::<()>().await;
        unreachable!()
    }

    /// The report must not hang. Before this fix the equivalent call inside
    /// `tokio::join!` ran for 3h43m (run 35022084038) and had to be cancelled
    /// by hand.
    #[tokio::test]
    async fn wedged_layer_returns_instead_of_hanging() {
        let t = Instant::now();
        let checks = with_deadline("L11 email_e2e", Duration::from_millis(200), never()).await;
        assert!(
            t.elapsed() < Duration::from_secs(5),
            "with_deadline did not return after its budget: {:?}",
            t.elapsed()
        );
        assert_eq!(checks.len(), 1, "a timed-out layer must emit exactly one check");
    }

    /// The timeout must be LOUD. A silently-dropped layer, or one reported as a
    /// healthy zero, reproduces the original defect one level down.
    #[tokio::test]
    async fn wedged_layer_is_loud_and_names_itself() {
        let checks = with_deadline("L11 email_e2e", Duration::from_millis(200), never()).await;
        let c = &checks[0];
        assert!(!c.passed, "a timed-out layer must NOT be reported as passing");
        assert_eq!(
            c.severity,
            Severity::Critical,
            "a timed-out layer must be Critical so it reaches summary.critical"
        );
        assert!(c.error.is_some(), "a timed-out layer must carry an error");
        assert!(
            c.name.contains("L11 email_e2e") && c.details.contains("L11 email_e2e"),
            "the check must NAME the layer that wedged, got name={:?} details={:?}",
            c.name,
            c.details
        );
        // The budget must be rendered honestly. `as_secs()` truncates this
        // 200ms budget to a flat "0s", which made the loud line read
        // "EXCEEDED ITS 0s DEADLINE" — an alarm that misstates its own
        // threshold is a worse alarm.
        assert!(
            c.details.contains("0.2s"),
            "sub-second budgets must not be truncated in the message, got {:?}",
            c.details
        );
    }

    /// A layer that finishes inside its budget must pass through byte-for-byte.
    /// This is the #342 guard: "Health Mail Full" is legitimately red on real
    /// numbers, and the deadline must not erase or rewrite a layer's findings.
    #[tokio::test]
    async fn healthy_layer_passes_through_unchanged() {
        let original = vec![Check {
            name: "E2E IMAP delivery".into(),
            passed: false,
            details: "real failure that must survive the deadline wrapper".into(),
            duration_ms: 178_000,
            error: Some("slow".into()),
            severity: Severity::Warning,
        }];
        let expected = original.clone();
        let got = with_deadline("L11 email_e2e", Duration::from_secs(30), async move {
            original
        })
        .await;
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].name, expected[0].name);
        assert_eq!(got[0].passed, expected[0].passed);
        assert_eq!(got[0].details, expected[0].details);
        assert_eq!(got[0].duration_ms, expected[0].duration_ms);
        assert_eq!(got[0].severity, expected[0].severity);
    }

    /// L11's budget must exceed the mail round-trip timeout it wraps, or the
    /// layer deadline would fire before the poll's own timeout could report.
    #[tokio::test]
    async fn email_budget_exceeds_the_declared_roundtrip() {
        let declared = reports_common::email_e2e::load_config()
            .map(|c| Duration::from_secs(c.timeout_secs))
            .unwrap_or(EMAIL_ROUNDTRIP_FALLBACK);
        let budget = declared + EMAIL_LAYER_MARGIN;
        assert!(
            budget > declared,
            "L11 budget {:?} must leave room above the declared round-trip {:?}",
            budget,
            declared
        );
        // #342 reports maddy=178s / stalwart=181s. Those must still be able to
        // finish and report rather than being cut off by the layer deadline.
        assert!(
            budget >= Duration::from_secs(181) + EMAIL_LAYER_MARGIN
                || budget >= Duration::from_secs(240),
            "L11 budget {:?} is too tight for the #342 mail timings",
            budget
        );
    }
}
