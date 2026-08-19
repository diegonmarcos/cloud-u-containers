use reqwest::Client;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;
use trust_dns_resolver::config::{NameServerConfig, Protocol, ResolverConfig, ResolverOpts};
use trust_dns_resolver::TokioAsyncResolver;

pub const TCP_TIMEOUT: Duration = Duration::from_secs(3);
pub const HTTP_TIMEOUT: Duration = Duration::from_secs(8);
pub const HICKORY_IP: &str = "10.0.0.1";

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

/// Native HTTP GET with reqwest
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

/// Build Hickory DNS resolver pointed at 10.0.0.1
pub fn hickory_resolver() -> TokioAsyncResolver {
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        format!("{}:53", HICKORY_IP).parse().unwrap(),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(3);
    opts.attempts = 2;
    TokioAsyncResolver::tokio(rc, opts)
}

/// Build public DNS resolver (1.1.1.1)
pub fn public_resolver() -> TokioAsyncResolver {
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        "1.1.1.1:53".parse().unwrap(),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(5);
    opts.attempts = 2;
    TokioAsyncResolver::tokio(rc, opts)
}

/// DNS A record lookup
pub async fn dns_resolve(resolver: &TokioAsyncResolver, name: &str) -> Option<String> {
    match timeout(Duration::from_secs(3), resolver.lookup_ip(name)).await {
        Ok(Ok(lookup)) => lookup.iter().next().map(|ip| ip.to_string()),
        _ => None,
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

/// DNS MX lookup
pub async fn dns_mx(resolver: &TokioAsyncResolver, name: &str) -> Vec<(String, String)> {
    match timeout(Duration::from_secs(5), resolver.mx_lookup(name)).await {
        Ok(Ok(lookup)) => lookup
            .iter()
            .map(|mx| (mx.preference().to_string(), mx.exchange().to_string()))
            .collect(),
        _ => vec![],
    }
}

/// Build standard HTTP client (no auth)
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

/// Parallel TCP scan
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

/// Check gcloud instance status (blocking — used sparingly)
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
    // Get tenancy from OCI config
    let home = std::env::var("HOME").unwrap_or_default();
    let config = std::fs::read_to_string(format!("{}/.oci/config", home)).ok()?;
    let tenancy = config.lines()
        .find(|l| l.starts_with("tenancy="))
        .and_then(|l| l.strip_prefix("tenancy="))
        .map(|s| s.to_string())?;
    let output = std::process::Command::new("oci")
        .args([
            "compute", "instance", "list",
            "--compartment-id", &tenancy,
            "--display-name", display_name,
            "--query", "data[0].\"lifecycle-state\"",
            "--raw-output",
        ])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() || s == "null" { None } else { Some(s) }
}

/// Cloud-agnostic VM status check
pub fn cloud_vm_status(_vm_id: &str, cloud_name: &str, provider: &str) -> Option<String> {
    match provider.to_lowercase().as_str() {
        "gcp" => gcloud_status(cloud_name),
        "oci" => oci_status(cloud_name),
        _ => None,
    }
}
