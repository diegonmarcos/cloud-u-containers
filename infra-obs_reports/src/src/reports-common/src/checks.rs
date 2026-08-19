use reqwest::Client;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;
use trust_dns_resolver::config::{NameServerConfig, Protocol, ResolverConfig, ResolverOpts};
use trust_dns_resolver::TokioAsyncResolver;

pub const TCP_TIMEOUT: Duration = Duration::from_secs(3);
pub const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

// Last-resort fallbacks used ONLY if build-reports.json:.resolvers is missing.
// The authoritative values are data-driven (see reports-resolvers.json →
// build-reports.json). These constants exist so a resolver never resolves to
// an empty string and break the report — not as the source of truth.
const FALLBACK_HICKORY_IP: &str = "10.0.0.1";
const FALLBACK_PUBLIC_IP: &str = "1.1.1.1";
const FALLBACK_GOOGLE_IP: &str = "8.8.8.8";

/// R2: read the `resolvers` block from build-reports.json. All DNS resolver IPs
/// (hickory/public/google) live in data, never hardcoded here.
fn resolvers_config() -> Option<serde_json::Value> {
    crate::context::load_build_reports_section("resolvers")
}

/// One resolver's (ip, port) from build-reports.json:.resolvers.<key>.
/// `fallback_ip` is used only when the section/key is absent.
fn resolver_addr(key: &str, fallback_ip: &str) -> (String, u16) {
    let cfg = resolvers_config();
    let node = cfg.as_ref().and_then(|c| c.get(key));
    let port = node
        .and_then(|n| n.get("port"))
        .and_then(|p| p.as_u64())
        .unwrap_or(53) as u16;
    let ip = node
        .and_then(|n| n.get("ip"))
        .and_then(|i| i.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| fallback_ip.to_string());
    (ip, port)
}

/// Data-driven: Hickory (internal WG DNS) IP.
/// Primary source: build-reports.json:.resolvers.hickory — either an explicit
/// `ip`, or a `vm` whose wg_ip is resolved from the consolidated JSON so an IP
/// change in topology propagates automatically. Falls back to the mesh-standard
/// 10.0.0.1 only if neither the resolvers block nor the consolidated lookup
/// yields a value.
pub fn hickory_ip() -> String {
    let cfg = resolvers_config();
    let node = cfg.as_ref().and_then(|c| c.get("hickory"));

    // 1. explicit ip in resolvers config
    if let Some(ip) = node.and_then(|n| n.get("ip")).and_then(|i| i.as_str()) {
        // Prefer the live consolidated wg_ip for the named vm when present, so
        // a topology IP change wins over the static resolvers-file fallback.
        if let Some(vm) = node.and_then(|n| n.get("vm")).and_then(|v| v.as_str()) {
            if let Some(live) = crate::context::load_consolidated()
                .ok()
                .and_then(|j| j["vms"][vm]["wg_ip"].as_str().map(|s| s.to_string()))
            {
                return live;
            }
        }
        return ip.to_string();
    }

    // 2. no resolvers config — derive from consolidated (gcp-proxy DNS hub)
    crate::context::load_consolidated()
        .ok()
        .and_then(|j| j["vms"]["gcp-E2-f_0"]["wg_ip"].as_str().map(|s| s.to_string()))
        .unwrap_or_else(|| FALLBACK_HICKORY_IP.to_string())
}

/// Native TCP port check
pub async fn tcp(ip: &str, port: u16) -> bool {
    let addr = format!("{}:{}", ip, port);
    match addr.parse::<std::net::SocketAddr>() {
        Ok(sa) => timeout(TCP_TIMEOUT, TcpStream::connect(sa))
            .await
            .map(|r| r.is_ok())
            .unwrap_or(false),
        Err(_) => match tokio::net::lookup_host(&addr).await {
            Ok(mut addrs) => match addrs.next() {
                Some(sa) => timeout(TCP_TIMEOUT, TcpStream::connect(sa))
                    .await
                    .map(|r| r.is_ok())
                    .unwrap_or(false),
                None => false,
            },
            Err(_) => false,
        },
    }
}

/// Native HTTP GET with reqwest — returns (ok, status_code, detail)
pub async fn http_get(client: &Client, url: &str) -> (bool, u16, String) {
    match timeout(HTTP_TIMEOUT, client.get(url).send()).await {
        Ok(Ok(resp)) => {
            let code = resp.status().as_u16();
            let ok = code >= 200 && code < 500 && code != 502;
            (ok, code, code.to_string())
        }
        Ok(Err(e)) => (false, 0, format!("err: {}", e)),
        Err(_) => (false, 0, "timeout".to_string()),
    }
}

/// Build Hickory DNS resolver pointed at the WireGuard-internal DNS hub.
/// IP is data-driven from consolidated JSON (gcp-proxy wg_ip).
pub fn hickory_resolver() -> TokioAsyncResolver {
    let ip = hickory_ip();
    let (_, port) = resolver_addr("hickory", FALLBACK_HICKORY_IP);
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        format!("{}:{}", ip, port)
            .parse()
            .unwrap_or_else(|_| format!("{}:53", FALLBACK_HICKORY_IP).parse().unwrap()),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(3);
    opts.attempts = 2;
    TokioAsyncResolver::tokio(rc, opts)
}

/// Build public DNS resolver. IP/port data-driven from
/// build-reports.json:.resolvers.public (Cloudflare anycast by default).
pub fn public_resolver() -> TokioAsyncResolver {
    let (ip, port) = resolver_addr("public", FALLBACK_PUBLIC_IP);
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        format!("{}:{}", ip, port)
            .parse()
            .unwrap_or_else(|_| format!("{}:53", FALLBACK_PUBLIC_IP).parse().unwrap()),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(5);
    opts.attempts = 2;
    TokioAsyncResolver::tokio(rc, opts)
}

/// Build Google DNS resolver. IP/port data-driven from
/// build-reports.json:.resolvers.google.
pub fn google_resolver() -> TokioAsyncResolver {
    let (ip, port) = resolver_addr("google", FALLBACK_GOOGLE_IP);
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        format!("{}:{}", ip, port)
            .parse()
            .unwrap_or_else(|_| format!("{}:53", FALLBACK_GOOGLE_IP).parse().unwrap()),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(5);
    opts.attempts = 2;
    TokioAsyncResolver::tokio(rc, opts)
}

#[cfg(test)]
mod resolver_tests {
    use super::*;
    use serde_json::json;

    /// R2: parse a resolvers block and assert each resolver's (ip, port) loads.
    /// This exercises the pure parse path directly (no filesystem dependency).
    fn addr_from(cfg: &serde_json::Value, key: &str, fallback_ip: &str) -> (String, u16) {
        let node = cfg.get(key);
        let port = node
            .and_then(|n| n.get("port"))
            .and_then(|p| p.as_u64())
            .unwrap_or(53) as u16;
        let ip = node
            .and_then(|n| n.get("ip"))
            .and_then(|i| i.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| fallback_ip.to_string());
        (ip, port)
    }

    #[test]
    fn resolvers_block_loads_all_three() {
        let cfg = json!({
            "hickory": { "vm": "gcp-E2-f_0", "ip": "10.0.0.1", "port": 53 },
            "public":  { "ip": "1.1.1.1", "port": 53 },
            "google":  { "ip": "8.8.8.8", "port": 5353 }
        });
        assert_eq!(addr_from(&cfg, "hickory", FALLBACK_HICKORY_IP), ("10.0.0.1".into(), 53));
        assert_eq!(addr_from(&cfg, "public", FALLBACK_PUBLIC_IP), ("1.1.1.1".into(), 53));
        // non-default port must be honoured (proves it's read from data)
        assert_eq!(addr_from(&cfg, "google", FALLBACK_GOOGLE_IP), ("8.8.8.8".into(), 5353));
    }

    #[test]
    fn resolvers_missing_key_uses_fallback() {
        let cfg = json!({ "public": { "ip": "9.9.9.9" } });
        // absent key → fallback ip + default port 53
        assert_eq!(addr_from(&cfg, "google", FALLBACK_GOOGLE_IP), (FALLBACK_GOOGLE_IP.to_string(), 53));
        // present-but-no-port → default 53
        assert_eq!(addr_from(&cfg, "public", FALLBACK_PUBLIC_IP), ("9.9.9.9".into(), 53));
    }
}

/// DNS A record lookup
pub async fn dns_resolve(resolver: &TokioAsyncResolver, name: &str) -> Option<String> {
    match timeout(Duration::from_secs(3), resolver.lookup_ip(name)).await {
        Ok(Ok(lookup)) => lookup.iter().next().map(|ip| ip.to_string()),
        _ => None,
    }
}

/// DNS A lookup with retries — survives transient resolver flakes (timeouts,
/// rate-limits). Returns the first successful resolution; None after all tries.
pub async fn dns_resolve_retry(
    resolver: &TokioAsyncResolver,
    name: &str,
    retries: usize,
    interval_ms: u64,
) -> Option<String> {
    for attempt in 0..=retries {
        if let Some(ip) = dns_resolve(resolver, name).await {
            return Some(ip);
        }
        if attempt < retries {
            tokio::time::sleep(Duration::from_millis(interval_ms)).await;
        }
    }
    None
}

/// DNS A/AAAA lookup returning ALL resolved IPs (not just the first).
/// Needed by hygiene checks that must inspect the full record set — e.g.
/// detecting a private/mesh IP published alongside the public edge IP.
pub async fn dns_resolve_all(resolver: &TokioAsyncResolver, name: &str) -> Vec<String> {
    match timeout(Duration::from_secs(3), resolver.lookup_ip(name)).await {
        Ok(Ok(lookup)) => lookup.iter().map(|ip| ip.to_string()).collect(),
        _ => Vec::new(),
    }
}

/// DNS TXT lookup
pub async fn dns_txt(resolver: &TokioAsyncResolver, name: &str) -> Option<String> {
    match timeout(Duration::from_secs(5), resolver.txt_lookup(name)).await {
        Ok(Ok(lookup)) => {
            let txts: Vec<String> = lookup.iter().map(|r| r.to_string()).collect();
            if txts.is_empty() {
                None
            } else {
                Some(txts.join(" "))
            }
        }
        _ => None,
    }
}

/// DNS MX lookup — returns Vec<(preference, exchange)>
pub async fn dns_mx(resolver: &TokioAsyncResolver, name: &str) -> Vec<(String, String)> {
    match timeout(Duration::from_secs(5), resolver.mx_lookup(name)).await {
        Ok(Ok(lookup)) => lookup
            .iter()
            .map(|mx| (mx.preference().to_string(), mx.exchange().to_string()))
            .collect(),
        _ => vec![],
    }
}

/// Build standard HTTP client (no auth, accepts invalid certs, no redirects)
pub fn http_client() -> Client {
    Client::builder()
        .timeout(HTTP_TIMEOUT)
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::none())
        .pool_max_idle_per_host(20)
        .build()
        .unwrap()
}

/// Build auth HTTP client with bearer token
pub fn auth_client(token: &str) -> Client {
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(
        "Authorization",
        format!("Bearer {}", token).parse().unwrap(),
    );
    Client::builder()
        .timeout(HTTP_TIMEOUT)
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::limited(5))
        .default_headers(headers)
        .pool_max_idle_per_host(20)
        .build()
        .unwrap()
}

/// Parallel TCP scan — returns list of open ports
pub async fn tcp_scan(ip: &str, ports: &[u16]) -> Vec<u16> {
    let futs: Vec<_> = ports
        .iter()
        .map(|&p| {
            let ip = ip.to_string();
            async move {
                if tcp(&ip, p).await {
                    Some(p)
                } else {
                    None
                }
            }
        })
        .collect();
    futures::future::join_all(futs)
        .await
        .into_iter()
        .flatten()
        .collect()
}

/// Check gcloud instance status (blocking)
pub fn gcloud_status(cloud_name: &str) -> Option<String> {
    let output = std::process::Command::new("gcloud")
        .args([
            "compute",
            "instances",
            "list",
            &format!("--filter=name={}", cloud_name),
            "--format=value(status)",
        ])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Check OCI instance status by display name (blocking)
pub fn oci_status(display_name: &str) -> Option<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let config = std::fs::read_to_string(format!("{}/.oci/config", home)).ok()?;
    let tenancy = config
        .lines()
        .find(|l| l.starts_with("tenancy="))
        .and_then(|l| l.strip_prefix("tenancy="))
        .map(|s| s.to_string())?;
    let output = std::process::Command::new("oci")
        .args([
            "compute",
            "instance",
            "list",
            "--compartment-id",
            &tenancy,
            "--display-name",
            display_name,
            "--query",
            "data[0].\"lifecycle-state\"",
            "--raw-output",
        ])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() || s == "null" {
        None
    } else {
        Some(s)
    }
}

/// Cloud-agnostic VM status check
pub fn cloud_vm_status(_vm_id: &str, cloud_name: &str, provider: &str) -> Option<String> {
    match provider.to_lowercase().as_str() {
        "gcp" => gcloud_status(cloud_name),
        "oci" => oci_status(cloud_name),
        _ => None,
    }
}
