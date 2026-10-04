use crate::context::NetworkContext;
use crate::types::PortScanResult;
use futures::stream::{self, StreamExt};
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::checks;
use reports_common::types::{Check, Severity};
use std::time::Instant;

/// Dangerous ports that should never be open to the public internet
const DANGEROUS_PORTS: &[u16] = &[21, 23, 3306, 5432, 6379, 27017];

/// Concurrency cap for per-VM port scans (TCP probes).
const PORT_SCAN_PARALLEL: usize = 8;

/// Dual-path port scan: external (public IP) + internal (WG IP) when available
pub async fn scan_all_vms(
    ctx: &NetworkContext,
    caps: &RuntimeCapabilities,
    fleet: Option<&reports_common::fleet::FleetState>,
) -> (Vec<Check>, Vec<PortScanResult>) {
    use reports_common::fleet::VmState;
    let mut all_checks = Vec::new();
    let mut all_results = Vec::new();

    // Skip Terminated VMs from the start — every dead host otherwise
    // burns ~3s × N ports of TCP timeouts.
    let is_terminated = |alias: &str| -> bool {
        fleet
            .map(|f| matches!(f.classify(alias), VmState::Terminated { .. }))
            .unwrap_or(false)
    };

    // ── External scan: public IPs ──
    let scannable: Vec<_> = ctx
        .vms
        .iter()
        .filter(|vm| !vm.pub_ip.is_empty() && vm.pub_ip != "?")
        .filter(|vm| !is_terminated(&vm.alias))
        .collect();

    println!("Port scan: {} VMs public + {} internal",
        scannable.len(),
        if caps.wg_up { ctx.vms.len().to_string() } else { "0 (no WG)".into() });

    let ext: Vec<(Vec<Check>, PortScanResult)> =
        stream::iter(scannable.into_iter().cloned())
            .map(|vm| async move {
                let t = Instant::now();

                // External probing is TCP-only (`tcp_scan` opens TCP sockets).
                // A declared UDP port (e.g. WireGuard :51821/udp) can NEVER show
                // as "open" over a TCP probe, so comparing it against the TCP
                // scan result produces a guaranteed false-positive
                // `declared_closed`. Only TCP-proto ports belong in the external
                // declared/closed comparison; UDP ports are tracked separately
                // for the report detail but never flagged as closed.
                let declared: Vec<u16> = vm
                    .public_ports
                    .iter()
                    .filter(|p| p.proto.eq_ignore_ascii_case("tcp"))
                    .map(|p| p.port)
                    .collect();
                let mut scan_ports: Vec<u16> = declared.clone();
                for &dp in DANGEROUS_PORTS {
                    if !scan_ports.contains(&dp) {
                        scan_ports.push(dp);
                    }
                }
                for &extra in &[22u16, 80, 443, 8080, 8443] {
                    if !scan_ports.contains(&extra) {
                        scan_ports.push(extra);
                    }
                }

                let open = checks::tcp_scan(&vm.pub_ip, &scan_ports).await;
                let elapsed = t.elapsed().as_millis() as u64;

                let undeclared_open: Vec<u16> = open
                    .iter()
                    .filter(|p| !declared.contains(p))
                    .copied()
                    .collect();
                let declared_closed: Vec<u16> = declared
                    .iter()
                    .filter(|p| !open.contains(p))
                    .copied()
                    .collect();

                let result = PortScanResult {
                    vm_alias: vm.alias.clone(),
                    ip: vm.pub_ip.clone(),
                    scan_path: "external".into(),
                    declared_ports: declared.clone(),
                    open_ports: open.clone(),
                    undeclared_open: undeclared_open.clone(),
                    declared_closed: declared_closed.clone(),
                };

                let mut checks_out = Vec::new();
                // The ONLY genuine external-exposure findings are ports that are
                // OPEN but not declared (a service exposed without being in the
                // topology). In this fail-closed WG-only architecture a declared
                // port that is found CLOSED externally is the EXPECTED hardened
                // state (e.g. gcp-proxy declares :25/:443 for its role but is a
                // pure WG hub with no public listener) — it is a security WIN,
                // not a finding. So `declared_closed` is reported as Info/passed,
                // never a Warning.
                let dangerous_open: Vec<u16> = undeclared_open
                    .iter()
                    .filter(|p| DANGEROUS_PORTS.contains(p))
                    .copied()
                    .collect();
                if !dangerous_open.is_empty() {
                    checks_out.push(Check {
                        name: format!("ext:port-scan:{}:dangerous", vm.alias),
                        passed: false,
                        details: format!(
                            "DANGEROUS ports open on {}: {:?}",
                            vm.pub_ip, dangerous_open
                        ),
                        duration_ms: elapsed,
                        error: None,
                        severity: Severity::Critical,
                    });
                }
                let non_dangerous: Vec<u16> = undeclared_open
                    .iter()
                    .filter(|p| !DANGEROUS_PORTS.contains(p))
                    .copied()
                    .collect();
                if !non_dangerous.is_empty() {
                    checks_out.push(Check {
                        name: format!("ext:port-scan:{}:undeclared", vm.alias),
                        passed: false,
                        details: format!(
                            "Undeclared open ports on {}: {:?}",
                            vm.pub_ip, non_dangerous
                        ),
                        duration_ms: elapsed,
                        error: None,
                        severity: Severity::Warning,
                    });
                }
                if dangerous_open.is_empty() && non_dangerous.is_empty() {
                    // No rogue exposure. Surface the clean state — and note any
                    // declared-but-closed ports as EXPECTED hardening, not a fault.
                    let details = if declared_closed.is_empty() {
                        format!("{} open={:?} (all declared)", vm.pub_ip, open)
                    } else {
                        format!(
                            "{} open={:?} — declared-closed {:?} EXPECTED (fail-closed / WG-only)",
                            vm.pub_ip, open, declared_closed
                        )
                    };
                    checks_out.push(Check {
                        name: format!("ext:port-scan:{}", vm.alias),
                        passed: true,
                        details,
                        duration_ms: elapsed,
                        error: None,
                        severity: Severity::Info,
                    });
                }
                (checks_out, result)
            })
            .buffer_unordered(PORT_SCAN_PARALLEL)
            .collect()
            .await;
    for (cs, r) in ext {
        for c in cs {
            all_checks.push(c);
        }
        all_results.push(r);
    }

    // ── Internal scan: WG IPs (when WG mesh is up) ──
    if caps.wg_up {
        let internal_inputs: Vec<_> = ctx
            .vms
            .iter()
            .filter(|vm| !vm.wg_ip.is_empty() && vm.wg_ip != "?")
            .filter(|vm| !is_terminated(&vm.alias))
            .cloned()
            .collect();
        let services = ctx.services.clone();
        let int_results: Vec<(Check, PortScanResult)> =
            stream::iter(internal_inputs.into_iter())
                .map(|vm| {
                    let services = services.clone();
                    async move {
                        let t = Instant::now();
                        let mut internal_ports: Vec<u16> = vec![22];
                        for svc_name in &vm.declared_services {
                            if let Some(svc) = services.iter().find(|s| &s.name == svc_name) {
                                if let Some(port) = svc.port {
                                    if !internal_ports.contains(&port) {
                                        internal_ports.push(port);
                                    }
                                }
                                for ct in &svc.containers {
                                    if let Some(port) = ct.port {
                                        if !internal_ports.contains(&port) {
                                            internal_ports.push(port);
                                        }
                                    }
                                }
                            }
                        }

                        let open = checks::tcp_scan(&vm.wg_ip, &internal_ports).await;
                        let elapsed = t.elapsed().as_millis() as u64;

                        let closed: Vec<u16> = internal_ports
                            .iter()
                            .filter(|p| !open.contains(p))
                            .copied()
                            .collect();

                        let result = PortScanResult {
                            vm_alias: vm.alias.clone(),
                            ip: vm.wg_ip.clone(),
                            scan_path: "internal".into(),
                            declared_ports: internal_ports.clone(),
                            open_ports: open.clone(),
                            undeclared_open: vec![],
                            declared_closed: closed.clone(),
                        };

                        let check = if closed.is_empty() {
                            Check {
                                name: format!("int:port-scan:{}", vm.alias),
                                passed: true,
                                details: format!(
                                    "WG {} — {}/{} service ports open",
                                    vm.wg_ip,
                                    open.len(),
                                    internal_ports.len()
                                ),
                                duration_ms: elapsed,
                                error: None,
                                severity: Severity::Info,
                            }
                        } else {
                            Check {
                                name: format!("int:port-scan:{}:closed", vm.alias),
                                passed: false,
                                details: format!(
                                    "WG {} — service ports unreachable: {:?}",
                                    vm.wg_ip, closed
                                ),
                                duration_ms: elapsed,
                                error: None,
                                severity: Severity::Warning,
                            }
                        };
                        (check, result)
                    }
                })
                .buffer_unordered(PORT_SCAN_PARALLEL)
                .collect()
                .await;
        for (c, r) in int_results {
            all_checks.push(c);
            all_results.push(r);
        }
    }

    (all_checks, all_results)
}
