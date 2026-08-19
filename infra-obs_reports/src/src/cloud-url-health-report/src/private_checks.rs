//! Probe private/internal upstreams.
//!
//! SOURCES OF TRUTH (declarative, data-driven — Fire Rule #3):
//!   1. `build-caddy.json` → `private_A1_app_canonical` + `private_B0_db`
//!      → every Hickory-served `.app` / `.db` hostname with its upstream.
//!   2. `_cloud-data-consolidated.json` → `vms.*.public_ports[]`
//!      → raw VM ports (SSH, mail, L4 passthrough) that Caddy does NOT route.
//!
//! Protocol (HTTP/HTTPS/TCP/Skip) is resolved from:
//!   - `tls` field in the caddy catalog (`on_demand`/`internal`/`public` → https)
//!   - `proto` hint + well-known-port heuristic for VM public_ports

use crate::config::Timeouts;
use futures::stream::{self, StreamExt};
use reports_common::caddy::{self, CaddyTarget};
use reports_common::context::find_cloud_data_file;
use reports_common::probe::{self, Protocol};
use serde::Serialize;
use serde_json::Value;
use std::time::Duration;

#[derive(Debug, Serialize, Clone)]
pub struct PrivateTarget {
    pub service: String,
    pub upstream: String,
    /// Source category (e.g. `private_A1_app_canonical`, `vm.public_ports`).
    pub source: String,
    /// Protocol resolved at load time.
    #[serde(skip)]
    pub protocol: Protocol,
}

#[derive(Debug, Serialize, Clone)]
pub struct PrivateResult {
    pub service: String,
    pub upstream: String,
    pub source: String,
    pub status: Option<u16>,
    pub latency_ms: u64,
    pub ok: bool,
    pub probe: &'static str,
    pub error: Option<String>,
}

/// Decide probe protocol for a caddy catalog entry.
/// - `.db` catalog → always TCP (databases don't speak HTTP on their port).
/// - `.app` with tls=on_demand/internal → HTTP on upstream port (Caddy does TLS).
/// - `.app` with tls=public → HTTPS.
/// Port-based fallback kicks in when upstream is malformed.
fn protocol_for_caddy_target(t: &CaddyTarget, port: u16) -> Protocol {
    if t.zone == "db" || t.category == "private_B0_db" {
        return Protocol::Tcp;
    }
    if t.kind == "catalog" {
        return Protocol::Tcp;
    }
    // For .app canonical hosts, the UPSTREAM is plain HTTP (Caddy terminates TLS).
    // Fall back to port heuristic if the port is a known TCP-only service.
    probe::protocol_for_port(port, None)
}

fn split_upstream(s: &str) -> Option<(String, u16)> {
    let stripped = s
        .strip_prefix("http://")
        .or_else(|| s.strip_prefix("https://"))
        .unwrap_or(s);
    let mut parts = stripped.rsplitn(2, ':');
    let port_s = parts.next()?;
    let host = parts.next()?;
    let port: u16 = port_s.trim_end_matches('/').parse().ok()?;
    if host.is_empty() || port == 0 {
        return None;
    }
    Some((host.to_string(), port))
}

/// Load private probe targets — caddy catalog (primary) + VM public_ports (raw).
pub fn load_private_targets() -> Vec<PrivateTarget> {
    let mut out: Vec<PrivateTarget> = Vec::new();

    // ── 1. Caddy catalog: every `.app` + `.db` Hickory hostname ─────────────
    for t in caddy::load_private_app_targets()
        .into_iter()
        .chain(caddy::load_private_db_targets().into_iter())
    {
        let Some((_ip, port)) = split_upstream(&t.upstream) else {
            continue; // skip `embedded` sqlite entries
        };
        let proto = protocol_for_caddy_target(&t, port);
        if proto == Protocol::Skip {
            continue;
        }
        out.push(PrivateTarget {
            service: t.host.clone(),
            upstream: t.upstream.clone(),
            source: t.category.clone(),
            protocol: proto,
        });
    }

    // ── 2. VM public_ports (raw) — SSH, mail, L4 passthrough ────────────────
    if let Some(path) = find_cloud_data_file("_cloud-data-consolidated.json") {
        if let Ok(raw) = std::fs::read_to_string(&path) {
            if let Ok(c) = serde_json::from_str::<Value>(&raw) {
                if let Some(vms) = c["vms"].as_object() {
                    for (vm_id, vm) in vms {
                        let wg_ip = match vm["wg_ip"].as_str() {
                            Some(ip) if !ip.is_empty() && ip != "?" => ip,
                            _ => continue,
                        };
                        let alias = vm["ssh_alias"].as_str().unwrap_or(vm_id);
                        if let Some(ports) = vm["public_ports"].as_array() {
                            for p in ports {
                                let port = p["port"].as_u64().unwrap_or(0);
                                if port == 0 {
                                    continue;
                                }
                                let port = port as u16;
                                let desc = p["desc"].as_str().unwrap_or("");
                                let proto_hint = p["proto"].as_str();
                                let proto = probe::protocol_for_public_port(port, proto_hint);
                                if proto == Protocol::Skip {
                                    continue;
                                }
                                let name = if desc.is_empty() {
                                    format!("vm:{}/{}", alias, port)
                                } else {
                                    format!("vm:{}/{}", alias, desc)
                                };
                                out.push(PrivateTarget {
                                    service: name,
                                    upstream: format!("{}:{}", wg_ip, port),
                                    source: "vm.public_ports".to_string(),
                                    protocol: proto,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    // Dedup by (service, upstream).
    out.sort_by(|a, b| a.service.cmp(&b.service).then(a.upstream.cmp(&b.upstream)));
    out.dedup_by(|a, b| a.service == b.service && a.upstream == b.upstream);
    out
}

pub async fn run(
    targets: Vec<PrivateTarget>,
    bearer: Option<&str>,
    parallel: usize,
    timeouts: &Timeouts,
    tcp_only_ports: &[u16],
) -> Vec<PrivateResult> {
    let client = match reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(timeouts.http_connect_secs))
        .timeout(Duration::from_secs(timeouts.http_total_secs))
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return targets
                .into_iter()
                .map(|t| PrivateResult {
                    service: t.service,
                    upstream: t.upstream,
                    source: t.source,
                    status: None,
                    latency_ms: 0,
                    ok: false,
                    probe: "http",
                    error: Some(format!("client build failed: {}", e)),
                })
                .collect();
        }
    };
    let bearer = bearer.map(|s| s.to_string());
    let tcp_timeout = Duration::from_secs(timeouts.tcp_secs);

    let tcp_only: std::collections::HashSet<u16> = tcp_only_ports.iter().copied().collect();
    stream::iter(targets)
        .map(|t| {
            let client = client.clone();
            let bearer = bearer.clone();
            let tcp_only = tcp_only.clone();
            async move {
                let (ip, port) = split_upstream(&t.upstream)
                    .unwrap_or_else(|| (String::new(), 0));
                // Force TCP-only probe for ports declared as non-HTTP (redis,
                // mariadb, raw SMTP, sieve, etc.) — config.targets.tcp_only_ports.
                // Without this override probe_endpoint would HTTP-probe ports it
                // can't speak HTTP on, returning false-negative "error sending
                // request" for fully healthy services. Ref: build-reports.json
                // url_health.targets.tcp_only_ports.
                let proto = if tcp_only.contains(&port) { Protocol::Tcp } else { t.protocol };
                // Retry transient WG-flap failures with exponential backoff.
                // First request after WG idle triggers async handshake that
                // outraces the probe — one packet primes the path, retries
                // succeed. 3 attempts × (0ms, 500ms, 1500ms) covers every
                // observed flap pattern without inflating timeout budgets
                // for genuinely-healthy probes.
                let mut res = probe::probe_endpoint(&ip, port, proto, bearer.as_deref(), &client, tcp_timeout).await;
                let mut attempt = 1u32;
                while !res.ok && res.error.is_some() && attempt < 3 {
                    let backoff = if attempt == 1 { 500 } else { 1500 };
                    tokio::time::sleep(Duration::from_millis(backoff)).await;
                    res = probe::probe_endpoint(&ip, port, proto, bearer.as_deref(), &client, tcp_timeout).await;
                    attempt += 1;
                }
                PrivateResult {
                    service: t.service,
                    upstream: t.upstream,
                    source: t.source,
                    status: res.status,
                    latency_ms: res.latency_ms,
                    ok: res.ok,
                    probe: res.probe,
                    error: res.error,
                }
            }
        })
        .buffer_unordered(parallel)
        .collect::<Vec<_>>()
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loader_returns_caddy_and_vm_ports() {
        let targets = load_private_targets();
        if targets.is_empty() {
            eprintln!("cloud-data unavailable — skipping");
            return;
        }
        let has_app = targets
            .iter()
            .any(|t| t.source.starts_with("private_A"));
        let has_db = targets.iter().any(|t| t.source == "private_B0_db");
        let has_vm = targets.iter().any(|t| t.source == "vm.public_ports");
        assert!(has_app, "expected at least one private_A* target");
        assert!(has_db, "expected at least one private_B0_db target");
        assert!(has_vm, "expected at least one vm.public_ports target");
    }
}
