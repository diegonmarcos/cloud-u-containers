use crate::context::NetworkContext;
use crate::types::WgPeerStatus;
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::ssh;
use reports_common::types::{Check, Severity};

/// Check WireGuard peer health via SSH to gcp-proxy
pub async fn check_wg(
    ctx: &NetworkContext,
    caps: &RuntimeCapabilities,
) -> (Vec<Check>, Vec<WgPeerStatus>) {
    let mut checks = Vec::new();
    let mut peers = Vec::new();

    // WireGuard peer health is read via `sudo wg show all dump` over SSH to
    // gcp-proxy — and ALL VM SSH is WG-only (port 22 is never public). In
    // external "friend-hacking" mode (no mesh membership) the mesh is down,
    // so this check is structurally impossible to run. Gate on `wg_up`, not on
    // the mere existence of `~/.ssh` (which is present on a GHA runner even
    // with no mesh): emit a single informational skip instead of a false
    // CRITICAL "could not resolve hostname gcp-proxy".
    if !caps.wg_up {
        checks.push(Check {
            name: "wg:health".into(),
            passed: true,
            details: "skipped — no mesh membership (external recon mode); WG health is a mesh-internal check".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, peers);
    }

    if !caps.ssh_available {
        checks.push(Check {
            name: "wg:ssh-unavailable".into(),
            passed: false,
            details: "SSH not available, skipping WireGuard check".into(),
            duration_ms: 0,
            error: Some("no SSH".into()),
            severity: Severity::Warning,
        });
        return (checks, peers);
    }

    let wg_output = match ssh::ssh_exec("gcp-proxy", "sudo wg show all dump", 15).await {
        Ok(output) => output,
        Err(e) => {
            checks.push(Check {
                name: "wg:gcp-proxy".into(),
                passed: false,
                details: format!("Failed to query WireGuard: {}", e),
                duration_ms: 0,
                error: Some(e.to_string()),
                severity: Severity::Critical,
            });
            return (checks, peers);
        }
    };

    // Build map of wg_ip -> vm_alias for cross-referencing
    let mut wg_ip_to_alias: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    for vm in &ctx.vms {
        if !vm.wg_ip.is_empty() && vm.wg_ip != "?" {
            // Store both with and without /32 suffix
            wg_ip_to_alias.insert(vm.wg_ip.clone(), vm.alias.clone());
            wg_ip_to_alias.insert(format!("{}/32", vm.wg_ip), vm.alias.clone());
        }
    }

    let now_epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Parse wg show all dump output
    // Interface lines: interface \t private-key \t public-key \t listen-port \t fwmark
    // Peer lines: interface \t public-key \t preshared-key \t endpoint \t allowed-ips \t latest-handshake \t transfer-rx \t transfer-tx \t persistent-keepalive
    let mut _current_interface = String::new();
    let mut peer_index = 0u32;

    for line in wg_output.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 4 {
            continue;
        }

        let iface = fields[0];

        if fields.len() == 5 {
            // Interface line
            _current_interface = iface.to_string();
            continue;
        }

        if fields.len() >= 8 {
            // Peer line: interface, public-key, preshared-key, endpoint, allowed-ips, latest-handshake, transfer-rx, transfer-tx[, persistent-keepalive]
            let _pub_key = fields[1];
            let endpoint = fields[3];
            let allowed_ips = fields[4];
            let handshake_epoch: u64 = fields[5].parse().unwrap_or(0);
            let rx: u64 = fields[6].parse().unwrap_or(0);
            let tx: u64 = fields[7].parse().unwrap_or(0);

            let handshake_age = if handshake_epoch > 0 {
                now_epoch.saturating_sub(handshake_epoch)
            } else {
                u64::MAX // never connected
            };

            // Match allowed-ips to a VM
            let name = allowed_ips
                .split(',')
                .find_map(|cidr| {
                    let ip = cidr.trim();
                    wg_ip_to_alias.get(ip).cloned()
                })
                .unwrap_or_else(|| {
                    peer_index += 1;
                    format!("peer-{}", peer_index)
                });

            let wg_ip = allowed_ips
                .split(',')
                .next()
                .unwrap_or("")
                .trim()
                .trim_end_matches("/32")
                .to_string();

            let healthy = handshake_age < 300;

            let status = WgPeerStatus {
                name: name.clone(),
                wg_ip: wg_ip.clone(),
                endpoint: endpoint.to_string(),
                last_handshake_secs: handshake_age,
                transfer_rx: rx,
                transfer_tx: tx,
                healthy,
            };

            let (severity, passed) = if handshake_age == u64::MAX {
                (Severity::Critical, false)
            } else if handshake_age > 900 {
                (Severity::Critical, false)
            } else if handshake_age > 300 {
                (Severity::Warning, false)
            } else {
                (Severity::Info, true)
            };

            let detail = if handshake_age == u64::MAX {
                format!("{} ({}) never connected", name, wg_ip)
            } else {
                format!(
                    "{} ({}) handshake {}s ago, rx={} tx={}",
                    name,
                    wg_ip,
                    handshake_age,
                    format_bytes(rx),
                    format_bytes(tx),
                )
            };

            checks.push(Check {
                name: format!("wg:{}", name),
                passed,
                details: detail,
                duration_ms: 0,
                error: None,
                severity,
            });

            peers.push(status);
        }
    }

    if peers.is_empty() {
        checks.push(Check {
            name: "wg:no-peers".into(),
            passed: false,
            details: "No WireGuard peers found in dump output".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Warning,
        });
    }

    (checks, peers)
}

fn format_bytes(bytes: u64) -> String {
    if bytes >= 1_073_741_824 {
        format!("{:.1}GiB", bytes as f64 / 1_073_741_824.0)
    } else if bytes >= 1_048_576 {
        format!("{:.1}MiB", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1024 {
        format!("{:.1}KiB", bytes as f64 / 1024.0)
    } else {
        format!("{}B", bytes)
    }
}
