use crate::context::NetworkContext;
use crate::types::{FirewallAuditResult, PortScanResult};
use futures::stream::{self, StreamExt};
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::ssh;
use reports_common::types::{Check, Severity};
use std::time::Instant;

/// Concurrency cap for per-VM SSH probes. The 5-VM home lab + transient
/// dead VMs means 8 is plenty of headroom; SSH multiplexing handles the
/// rest. Higher values just increase blast radius if one VM hangs.
const FIREWALL_AUDIT_PARALLEL: usize = 8;

/// Audit firewall state on each VM by comparing `ss -tlnp` with declared ports
pub async fn audit_firewalls(
    ctx: &NetworkContext,
    port_data: &[PortScanResult],
    caps: &RuntimeCapabilities,
    fleet: Option<&reports_common::fleet::FleetState>,
) -> (Vec<Check>, Vec<FirewallAuditResult>) {
    use reports_common::fleet::VmState;
    let mut checks = Vec::new();
    let mut results = Vec::new();

    // The firewall audit runs `ss -tlnp` over SSH on each VM, and all VM SSH is
    // WG-only (port 22 is never public). In external "friend-hacking" mode (no
    // mesh membership) every VM is SSH-unreachable BY DESIGN — that is the
    // intended posture, not a fault. Gate on `wg_up` (real mesh reachability),
    // not on `~/.ssh` existence, and emit a single informational skip rather
    // than one false WARNING per VM.
    if !caps.wg_up {
        checks.push(Check {
            name: "firewall:audit".into(),
            passed: true,
            details: "skipped — no mesh membership (external recon mode); per-VM ss audit is a mesh-internal check (SSH is WG-only by design)".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, results);
    }

    if !caps.ssh_available {
        checks.push(Check {
            name: "firewall:ssh-unavailable".into(),
            passed: false,
            details: "SSH not available, skipping firewall audit".into(),
            duration_ms: 0,
            error: Some("no SSH".into()),
            severity: Severity::Warning,
        });
        return (checks, results);
    }

    // Skip Terminated VMs at step 0 — `ss -tlnp` over SSH on a dead host
    // bleeds the SSH-handshake deadline (~10s) per VM.
    let live_vms: Vec<_> = ctx
        .vms
        .iter()
        .filter(|vm| {
            fleet
                .map(|f| !matches!(f.classify(&vm.alias), VmState::Terminated { .. }))
                .unwrap_or(true)
        })
        .cloned()
        .collect();
    println!(
        "Firewall audit: {}/{} VMs (skipped {} Terminated)",
        live_vms.len(),
        ctx.vms.len(),
        ctx.vms.len() - live_vms.len()
    );

    // Snapshot per-VM declared ports from port_data so the per-VM async
    // closure can be `move` without holding a reference to `port_data`.
    let scan_declared_by_alias: std::collections::HashMap<String, Vec<u16>> = port_data
        .iter()
        .map(|p| (p.vm_alias.clone(), p.declared_ports.clone()))
        .collect();

    let outputs: Vec<(Check, Option<FirewallAuditResult>)> =
        stream::iter(live_vms.into_iter())
            .map(|vm| {
                let scan_declared = scan_declared_by_alias.get(&vm.alias).cloned().unwrap_or_default();
                async move {
                    let t = Instant::now();

                    if !ssh::ssh_echo_test(&vm.alias).await {
                        return (
                            Check {
                                name: format!("firewall:{}", vm.alias),
                                passed: false,
                                details: "SSH unreachable, cannot audit firewall".into(),
                                duration_ms: t.elapsed().as_millis() as u64,
                                error: Some("SSH unreachable".into()),
                                severity: Severity::Warning,
                            },
                            None,
                        );
                    }

                    let ss_output = match ssh::ssh_exec(&vm.alias, "ss -tlnp", 10).await {
                        Ok(out) => out,
                        Err(e) => {
                            return (
                                Check {
                                    name: format!("firewall:{}", vm.alias),
                                    passed: false,
                                    details: format!("Failed to run ss: {}", e),
                                    duration_ms: t.elapsed().as_millis() as u64,
                                    error: Some(e.to_string()),
                                    severity: Severity::Warning,
                                },
                                None,
                            );
                        }
                    };

                    let elapsed = t.elapsed().as_millis() as u64;
                    let listening_ports = parse_ss_output(&ss_output);
                    let declared: Vec<u16> = vm.public_ports.iter().map(|p| p.port).collect();
                    let mut all_declared = declared.clone();
                    for p in &scan_declared {
                        if !all_declared.contains(p) {
                            all_declared.push(*p);
                        }
                    }
                    let system_ports: [u16; 1] = [22];
                    let rogue: Vec<u16> = listening_ports
                        .iter()
                        .filter(|p| !all_declared.contains(p) && !system_ports.contains(p))
                        .copied()
                        .collect();

                    let result = FirewallAuditResult {
                        vm_alias: vm.alias.clone(),
                        open_ports: listening_ports.clone(),
                        declared_ports: all_declared.clone(),
                        rogue_ports: rogue.clone(),
                    };

                    let check = if rogue.is_empty() {
                        Check {
                            name: format!("firewall:{}", vm.alias),
                            passed: true,
                            details: format!(
                                "{} listening ports, all declared",
                                listening_ports.len()
                            ),
                            duration_ms: elapsed,
                            error: None,
                            severity: Severity::Info,
                        }
                    } else {
                        Check {
                            name: format!("firewall:{}:rogue", vm.alias),
                            passed: false,
                            details: format!("Rogue listeners on 0.0.0.0: {:?}", rogue),
                            duration_ms: elapsed,
                            error: None,
                            severity: Severity::Warning,
                        }
                    };
                    (check, Some(result))
                }
            })
            .buffer_unordered(FIREWALL_AUDIT_PARALLEL)
            .collect()
            .await;

    for (check, maybe_result) in outputs {
        checks.push(check);
        if let Some(r) = maybe_result {
            results.push(r);
        }
    }

    (checks, results)
}

/// Parse `ss -tlnp` output and extract ports listening on 0.0.0.0 or [::]
fn parse_ss_output(output: &str) -> Vec<u16> {
    let mut ports = Vec::new();

    for line in output.lines().skip(1) {
        // Lines look like:
        // LISTEN 0  4096  0.0.0.0:443  0.0.0.0:*  users:(("caddy",pid=...))
        // LISTEN 0  4096  [::]:80      [::]:*
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 5 {
            continue;
        }

        let state = fields[0];
        if state != "LISTEN" {
            continue;
        }

        let local_addr = fields[3];

        // Check if bound to all interfaces
        let is_wildcard = local_addr.starts_with("0.0.0.0:")
            || local_addr.starts_with("*:")
            || local_addr.starts_with("[::]:");

        if !is_wildcard {
            continue;
        }

        // Extract port (last part after the last colon)
        if let Some(port_str) = local_addr.rsplit(':').next() {
            if let Ok(port) = port_str.parse::<u16>() {
                if !ports.contains(&port) {
                    ports.push(port);
                }
            }
        }
    }

    ports.sort();
    ports
}
