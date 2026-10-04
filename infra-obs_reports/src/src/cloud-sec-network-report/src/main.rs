mod types;
mod context;
mod port_scan;
mod tls_audit;
mod wireguard;
mod dns_audit;
mod firewall;
mod output;

use anyhow::Result;
use std::collections::HashMap;
use std::time::Instant;

#[tokio::main]
async fn main() -> Result<()> {
    let start = Instant::now();
    println!("Cloud Security: Network Report");
    println!("==============================\n");

    // Load context
    let ctx = context::load_context()?;
    let caps = reports_common::capabilities::RuntimeCapabilities::detect().await;

    // Load master's fleet preflight (best-effort) so port_scan + firewall
    // can skip Terminated VMs at step 0 instead of burning per-port TCP
    // timeouts on a dead public IP.
    let snapshot_fleet = {
        use reports_common::run_state::{RunState, RUN_STATE_FILENAME};
        let path = std::path::PathBuf::from(RUN_STATE_FILENAME);
        match RunState::load(&path) {
            Ok(rs) => rs.fleet_state,
            Err(_) => None,
        }
    };

    // Phase 1: Port scan all VMs (parallel)
    let t = Instant::now();
    let (port_checks, port_data) =
        port_scan::scan_all_vms(&ctx, &caps, snapshot_fleet.as_ref()).await;
    let port_ms = t.elapsed().as_millis() as u64;
    println!("⏱  port_scan: {:.1}s", port_ms as f64 / 1000.0);

    // Phase 2: Parallel — TLS, DNS, WireGuard
    let t = Instant::now();
    let (tls_result, dns_result, wg_result) = tokio::join!(
        tls_audit::audit_all_certs(&ctx, &caps),
        dns_audit::validate_dns(&ctx, &caps),
        wireguard::check_wg(&ctx, &caps),
    );
    let (tls_checks, _tls_data) = tls_result;
    let (dns_checks, _dns_data) = dns_result;
    let (wg_checks, _wg_data) = wg_result;
    let parallel_ms = t.elapsed().as_millis() as u64;
    println!("⏱  tls+dns+wg parallel: {:.1}s", parallel_ms as f64 / 1000.0);

    // Phase 3: Firewall audit (needs port_data + SSH)
    let t = Instant::now();
    let (fw_checks, _fw_data) =
        firewall::audit_firewalls(&ctx, &port_data, &caps, snapshot_fleet.as_ref()).await;
    let fw_ms = t.elapsed().as_millis() as u64;
    println!("⏱  firewall_audit: {:.1}s", fw_ms as f64 / 1000.0);

    let duration_ms = start.elapsed().as_millis() as u64;
    println!(
        "=== cloud-sec-network DONE in {:.1}s === port={:.1}s parallel={:.1}s firewall={:.1}s",
        duration_ms as f64 / 1000.0,
        port_ms as f64 / 1000.0,
        parallel_ms as f64 / 1000.0,
        fw_ms as f64 / 1000.0,
    );

    // Collect all checks
    let all_checks: Vec<&reports_common::types::Check> = port_checks
        .iter()
        .chain(&tls_checks)
        .chain(&dns_checks)
        .chain(&wg_checks)
        .chain(&fw_checks)
        .collect();

    let summary = reports_common::types::Summary::from_checks(&all_checks);

    // Timers
    let mut timers = HashMap::new();
    timers.insert("Port scan".into(), port_ms);
    timers.insert("TLS+DNS+WG (parallel)".into(), parallel_ms);
    timers.insert("Firewall audit".into(), fw_ms);

    // Build template vars
    let vars = output::build_template_vars(
        &port_checks,
        &tls_checks,
        &dns_checks,
        &wg_checks,
        &fw_checks,
        &all_checks,
        &summary,
        &timers,
        duration_ms,
    );

    // Render template
    reports_common::template::render(
        "cloud_sec_network.md.tpl",
        "cloud_sec_network.md",
        &vars,
    )?;

    // Write JSON
    let json_out = serde_json::json!({
        "generated": chrono::Utc::now().to_rfc3339(),
        "duration_ms": duration_ms,
        "port_scan": port_data,
        "summary": summary,
    });
    std::fs::write(
        "cloud_sec_network.json",
        serde_json::to_string_pretty(&json_out)?,
    )?;
    println!("Wrote cloud_sec_network.json");

    // Merge into shared run-state snapshot for master appendix re-render.
    {
        use reports_common::run_state::{RunState, RUN_STATE_FILENAME};
        let path = std::path::PathBuf::from(RUN_STATE_FILENAME);
        if let Err(e) =
            RunState::merge_section(&path, |s| s.sec_network = Some(json_out.clone()))
        {
            eprintln!("[run_state] sec-network merge failed: {e}");
        } else {
            println!("[run_state] merged sec_network slice into {}", path.display());
        }
    }

    Ok(())
}
