//! Data-driven endpoint probing — shared across all report crates.
//! Reads `protocol` / `public` fields from consolidated JSON container specs,
//! falls back to a well-known-port heuristic when unset.

use serde::Serialize;
use serde_json::Value;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum Protocol {
    Http,
    Https,
    Tcp,
    Udp,
    /// Not probeable (e.g. docker-bridge only, public:false).
    Skip,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProbeResult {
    pub ok: bool,
    pub status: Option<u16>,
    pub probe: &'static str,
    pub latency_ms: u64,
    pub error: Option<String>,
}

impl ProbeResult {
    pub fn skipped(reason: &str) -> Self {
        Self {
            ok: true,
            status: None,
            probe: "skip",
            latency_ms: 0,
            error: Some(reason.to_string()),
        }
    }
}

/// Resolve protocol for a container spec from `.services.<svc>.containers.<name>`.
/// `container_json` may be Null / missing — caller can pass Value::Null to force heuristic.
pub fn protocol_for_container(container_json: &Value, port: u16) -> Protocol {
    // public:false → bound to docker bridge only, not reachable over WG.
    if container_json
        .get("public")
        .and_then(|v| v.as_bool())
        == Some(false)
    {
        return Protocol::Skip;
    }
    if let Some(p) = container_json.get("protocol").and_then(|v| v.as_str()) {
        return parse_proto_str(p, port);
    }
    protocol_for_port(port, None)
}

/// Resolve protocol from a VM `public_ports[]` entry: `{ port, proto, desc }`.
pub fn protocol_for_public_port(port: u16, proto_hint: Option<&str>) -> Protocol {
    protocol_for_port(port, proto_hint)
}

/// Fallback heuristic when `.protocol` is not declared. Covers the 23/83 containers
/// that omit the field, plus VM public_port entries where `proto` is just "tcp"/"udp"
/// without telling us whether it's http-over-tcp.
pub fn protocol_for_port(port: u16, proto_hint: Option<&str>) -> Protocol {
    // Explicit hints win.
    if let Some(p) = proto_hint {
        match p.to_ascii_lowercase().as_str() {
            "http" => return Protocol::Http,
            "https" => return Protocol::Https,
            "udp" => return Protocol::Udp,
            // "tcp" alone is ambiguous — fall through to port-based decision
            _ => {}
        }
    }

    // Well-known non-HTTP TCP ports.
    const TCP_ONLY: &[u16] = &[
        22, 25, 53, 143, 465, 587, 993, // SMTP/IMAP/SSH/DNS
        3306,                             // MySQL
        4190, 6190,                       // ManageSieve
        5432, 5433, 5434, 5435, 5436, 5437, 5438, 5439, 5440, 5441, 5442, 5443, // Postgres
        6379, 6380, 6381,                 // Redis
        8001,                             // kg-graph raw
        11434,                            // Ollama
        2025, 2222, 2223, 2224, 2443, 2465, 2587, 2993, // mail/backup shadow ports
        21027, 22000,                     // Syncthing
        8443,                             // Maddy admin (TLS)
        // B8 fix: raw-IP probes to Caddy on 80/443 can't carry a meaningful
        // Host header — Caddy returns 404 ("no site for <ip>") and we'd
        // call that a failure despite the edge being perfectly healthy.
        // Downgrade to TCP-only so we assert reachability without expecting
        // a specific HTTP status. Probes targeted at a real domain
        // (https://<host>) don't pass through this heuristic.
        80,                               // HTTP edge — no Host = 404 on bare IP
        443,                              // HTTPS — no SNI = TLS handshake fails on bare IP
    ];
    if TCP_ONLY.contains(&port) {
        return Protocol::Tcp;
    }
    // Default: assume HTTP. Most remaining app ports are 3xxx/8xxx HTTP services.
    Protocol::Http
}

fn parse_proto_str(p: &str, port: u16) -> Protocol {
    match p.to_ascii_lowercase().as_str() {
        "http" => Protocol::Http,
        "https" => Protocol::Https,
        "tcp" => Protocol::Tcp,
        "udp" => Protocol::Udp,
        _ => protocol_for_port(port, None),
    }
}

/// Probe a single endpoint. Returns a ProbeResult with probe type + outcome.
pub async fn probe_endpoint(
    ip: &str,
    port: u16,
    protocol: Protocol,
    bearer: Option<&str>,
    http_client: &reqwest::Client,
    tcp_timeout: Duration,
) -> ProbeResult {
    match protocol {
        Protocol::Skip => ProbeResult::skipped("container bound to docker bridge only (public:false)"),
        Protocol::Udp => ProbeResult::skipped("UDP — no active probe"),
        Protocol::Tcp => tcp_probe(ip, port, tcp_timeout).await,
        Protocol::Http | Protocol::Https => http_probe(ip, port, protocol, bearer, http_client).await,
    }
}

async fn tcp_probe(ip: &str, port: u16, timeout: Duration) -> ProbeResult {
    let start = Instant::now();
    match tokio::time::timeout(
        timeout,
        tokio::net::TcpStream::connect((ip, port)),
    )
    .await
    {
        Ok(Ok(_)) => ProbeResult {
            ok: true,
            status: None,
            probe: "tcp",
            latency_ms: start.elapsed().as_millis() as u64,
            error: None,
        },
        Ok(Err(e)) => ProbeResult {
            ok: false,
            status: None,
            probe: "tcp",
            latency_ms: start.elapsed().as_millis() as u64,
            error: Some(e.to_string()),
        },
        Err(_) => ProbeResult {
            ok: false,
            status: None,
            probe: "tcp",
            latency_ms: start.elapsed().as_millis() as u64,
            error: Some(format!("tcp connect timeout {}s", timeout.as_secs())),
        },
    }
}

async fn http_probe(
    ip: &str,
    port: u16,
    proto: Protocol,
    bearer: Option<&str>,
    client: &reqwest::Client,
) -> ProbeResult {
    let scheme = if proto == Protocol::Https { "https" } else { "http" };
    let url = format!("{}://{}:{}/", scheme, ip, port);
    let mut req = client.get(&url);
    if let Some(b) = bearer {
        req = req.bearer_auth(b);
    }
    let start = Instant::now();
    match req.send().await {
        Ok(r) => {
            let status = r.status().as_u16();
            // Liveness — service responded (we never sent a real workload):
            //   200-399 ok/redirect, 401/403 auth-gated, 404 no-root, 405 wrong-method,
            //   400 malformed-for-this-protocol (WS-only endpoints reject bare GET with 400).
            let ok = r.status().is_success()
                || r.status().is_redirection()
                || matches!(status, 400 | 401 | 403 | 404 | 405);
            ProbeResult {
                ok,
                status: Some(status),
                probe: "http",
                latency_ms: start.elapsed().as_millis() as u64,
                error: None,
            }
        }
        Err(e) => ProbeResult {
            ok: false,
            status: None,
            probe: "http",
            latency_ms: start.elapsed().as_millis() as u64,
            error: Some(e.to_string()),
        },
    }
}
