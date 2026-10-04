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

/// Run openssl s_client check via subprocess (for TLS probing mail ports)
pub async fn openssl_connect(host: &str, port: u16, starttls: Option<&str>) -> (bool, String) {
    openssl_connect_inner(host, port, host, starttls).await
}

/// Same as openssl_connect but lets the caller probe an explicit address while
/// keeping a different SNI (useful for WG-IP probes against a public cert name).
pub async fn openssl_connect_wg(
    addr: &str,
    port: u16,
    sni: &str,
    starttls: Option<&str>,
) -> (bool, String) {
    openssl_connect_inner(addr, port, sni, starttls).await
}

async fn openssl_connect_inner(
    addr: &str,
    port: u16,
    sni: &str,
    starttls: Option<&str>,
) -> (bool, String) {
    let mut args = vec![
        "s_client".to_string(),
        "-connect".to_string(),
        format!("{}:{}", addr, port),
        "-servername".to_string(),
        sni.to_string(),
    ];
    if let Some(proto) = starttls {
        args.push("-starttls".to_string());
        args.push(proto.to_string());
    }

    let result = timeout(Duration::from_secs(5), async {
        let mut child = tokio::process::Command::new("openssl")
            .args(&args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()?;
        // Write "Q\n" to stdin and drop it
        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            let _ = stdin.write_all(b"Q\n").await;
            drop(stdin);
        }
        child.wait_with_output().await
    })
    .await;

    match result {
        Ok(Ok(output)) => {
            let combined = format!(
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            let connected = combined.contains("CONNECTED");
            let expiry = combined
                .lines()
                .find(|l| l.contains("Not After"))
                .map(|l| l.trim().to_string());
            let detail = if connected {
                if let Some(exp) = expiry {
                    format!("TLS OK ({})", exp)
                } else {
                    "TLS OK".to_string()
                }
            } else {
                "FAIL".to_string()
            };
            (connected, detail)
        }
        _ => (false, "timeout/error".to_string()),
    }
}

/// Run a curl command and return (ok, http_code_string)
#[allow(dead_code)]
pub async fn curl_status(url: &str, timeout_secs: u64) -> (bool, String) {
    let result = timeout(
        Duration::from_secs(timeout_secs + 2),
        tokio::process::Command::new("curl")
            .args([
                "-sk",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "--max-time",
                &timeout_secs.to_string(),
                url,
            ])
            .output(),
    )
    .await;

    match result {
        Ok(Ok(output)) if output.status.success() => {
            let code = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let ok = matches!(code.as_str(), "200" | "301" | "302" | "303");
            (ok, code)
        }
        _ => (false, "0".to_string()),
    }
}
