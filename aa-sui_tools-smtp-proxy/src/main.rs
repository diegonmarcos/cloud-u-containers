use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use hickory_resolver::{
    config::{ResolverConfig, ResolverOpts},
    TokioAsyncResolver,
};
use lettre::{
    address::Envelope, AsyncSmtpTransport, AsyncTransport, Tokio1Executor,
    transport::smtp::authentication::Credentials,
    transport::smtp::extension::ClientId,
};
use serde_json::{json, Value};
use std::{env, net::IpAddr, str::FromStr, sync::Arc};
use tracing::{info, warn, error};

// ── Config ──────────────────────────────────────────────────────────

struct Config {
    smtp_host: String,
    smtp_port: u16,
    smtp_user: String,
    smtp_pass: String,
    api_key: String,
    listen_port: u16,
    helo_domain: String,
}

impl Config {
    fn from_env() -> Self {
        Self {
            smtp_host: env::var("SMTP_HOST").unwrap_or_else(|_| "127.0.0.1".into()),
            smtp_port: env::var("SMTP_PORT").unwrap_or_else(|_| "25".into()).parse().unwrap_or(25),
            smtp_user: env::var("SMTP_USER").unwrap_or_else(|_| "me@diegonmarcos.com".into()),
            smtp_pass: env::var("SMTP_PASS").unwrap_or_default(),
            api_key: env::var("API_KEY").unwrap_or_default(),
            listen_port: env::var("LISTEN_PORT").unwrap_or_else(|_| "8080".into()).parse().unwrap_or(8080),
            helo_domain: "smtp-proxy.diegonmarcos.com".into(),
        }
    }
}

// ── Email header parsing ────────────────────────────────────────────

fn extract_header(body: &[u8], name: &str) -> Option<String> {
    let text = String::from_utf8_lossy(body);
    let header_section = text.split("\r\n\r\n").next()
        .or_else(|| text.split("\n\n").next())?;

    let target = format!("{}:", name.to_lowercase());
    let mut value = String::new();
    let mut found = false;

    for line in header_section.lines() {
        if found {
            if line.starts_with(' ') || line.starts_with('\t') {
                value.push(' ');
                value.push_str(line.trim());
            } else {
                break;
            }
        } else if line.to_lowercase().starts_with(&target) {
            value = line[name.len() + 1..].trim().to_string();
            found = true;
        }
    }
    if found { Some(value) } else { None }
}

fn extract_address(body: &[u8], name: &str) -> Option<String> {
    let raw = extract_header(body, name)?;
    if let Some(start) = raw.rfind('<') {
        if let Some(end) = raw.rfind('>') {
            return Some(raw[start + 1..end].to_string());
        }
    }
    Some(raw)
}

// ── Security checks ─────────────────────────────────────────────────

const DNSBL_LISTS: &[&str] = &["zen.spamhaus.org", "bl.spamcop.net"];
const MAX_SPF_LOOKUPS: u8 = 10;

#[derive(Debug, Clone, Copy, PartialEq)]
enum SpfResult { Pass, Fail, SoftFail, Neutral, None, TempError }

impl std::fmt::Display for SpfResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pass => write!(f, "pass"),
            Self::Fail => write!(f, "fail"),
            Self::SoftFail => write!(f, "softfail"),
            Self::Neutral => write!(f, "neutral"),
            Self::None => write!(f, "none"),
            Self::TempError => write!(f, "temperror"),
        }
    }
}

struct SecurityResults {
    rdns: Option<String>,
    rdns_pass: bool,
    dnsbl_listed: Vec<String>,
    spf: SpfResult,
}

async fn check_rdns(resolver: &TokioAsyncResolver, ip: IpAddr) -> (Option<String>, bool) {
    match resolver.reverse_lookup(ip).await {
        Ok(lookup) => match lookup.iter().next() {
            Some(name) => {
                let hostname = name.to_string().trim_end_matches('.').to_string();
                (Some(hostname), true)
            }
            None => (None, false),
        },
        Err(_) => (None, false),
    }
}

async fn check_dnsbl(resolver: &TokioAsyncResolver, ip: IpAddr, blocklist: &str) -> bool {
    let query = match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            format!("{}.{}.{}.{}.{blocklist}", o[3], o[2], o[1], o[0])
        }
        IpAddr::V6(v6) => {
            let nibbles: String = v6.octets().iter().rev()
                .flat_map(|b| [format!("{:x}", b & 0xf), format!("{:x}", (b >> 4) & 0xf)])
                .collect::<Vec<_>>()
                .join(".");
            format!("{nibbles}.{blocklist}")
        }
    };
    resolver.lookup_ip(&query).await.is_ok()
}

fn ip_in_cidr(ip: IpAddr, cidr: &str) -> bool {
    if let Some((addr_str, prefix_str)) = cidr.split_once('/') {
        let Ok(net) = IpAddr::from_str(addr_str) else { return false };
        let Ok(prefix) = prefix_str.parse::<u8>() else { return false };
        match (ip, net) {
            (IpAddr::V4(a), IpAddr::V4(b)) => {
                if prefix > 32 { return false; }
                let mask = if prefix == 0 { 0u32 } else { !0u32 << (32 - prefix) };
                u32::from(a) & mask == u32::from(b) & mask
            }
            (IpAddr::V6(a), IpAddr::V6(b)) => {
                if prefix > 128 { return false; }
                let mask = if prefix == 0 { 0u128 } else { !0u128 << (128 - prefix) };
                u128::from(a) & mask == u128::from(b) & mask
            }
            _ => false,
        }
    } else {
        IpAddr::from_str(cidr).map_or(false, |addr| addr == ip)
    }
}

async fn check_spf(
    resolver: &TokioAsyncResolver, ip: IpAddr, domain: &str, depth: u8,
) -> SpfResult {
    if depth >= MAX_SPF_LOOKUPS { return SpfResult::TempError; }

    let txt = match resolver.txt_lookup(domain).await {
        Ok(r) => r,
        Err(_) => return SpfResult::None,
    };

    let record = match txt.iter().map(|r| r.to_string()).find(|r| r.starts_with("v=spf1")) {
        Some(r) => r,
        None => return SpfResult::None,
    };

    for token in record.split_whitespace().skip(1) {
        let (qual, mech) = match token.as_bytes().first() {
            Some(b'+') | Some(b'-') | Some(b'~') | Some(b'?') =>
                (token.chars().next().unwrap(), &token[1..]),
            _ => ('+', token),
        };
        let result = match qual {
            '-' => SpfResult::Fail,
            '~' => SpfResult::SoftFail,
            '?' => SpfResult::Neutral,
            _ => SpfResult::Pass,
        };

        // ip4:/ip6: — direct CIDR match
        if mech.starts_with("ip4:") || mech.starts_with("ip6:") {
            if ip_in_cidr(ip, &mech[4..]) { return result; }
            continue;
        }

        // include: — recursive SPF
        if mech.starts_with("include:") {
            if matches!(
                Box::pin(check_spf(resolver, ip, &mech[8..], depth + 1)).await,
                SpfResult::Pass
            ) { return SpfResult::Pass; }
            continue;
        }

        // a / a:domain — A/AAAA record match
        if mech == "a" || mech.starts_with("a:") {
            let target = if mech == "a" { domain } else { &mech[2..] };
            if let Ok(addrs) = resolver.lookup_ip(target).await {
                if addrs.iter().any(|a| a == ip) { return result; }
            }
            continue;
        }

        // mx / mx:domain — MX host IP match
        if mech == "mx" || mech.starts_with("mx:") {
            let target = if mech == "mx" { domain } else { &mech[3..] };
            if let Ok(mx_records) = resolver.mx_lookup(target).await {
                for mx in mx_records.iter() {
                    let host = mx.exchange().to_string();
                    if let Ok(addrs) = resolver.lookup_ip(host.trim_end_matches('.')).await {
                        if addrs.iter().any(|a| a == ip) { return result; }
                    }
                }
            }
            continue;
        }

        // all — catch-all
        if mech == "all" { return result; }
    }

    SpfResult::Neutral
}

async fn run_checks(resolver: &TokioAsyncResolver, ip: IpAddr, domain: &str) -> SecurityResults {
    let (rdns, dnsbl, spf) = tokio::join!(
        check_rdns(resolver, ip),
        async {
            let mut listed = Vec::new();
            for bl in DNSBL_LISTS {
                if check_dnsbl(resolver, ip, bl).await {
                    listed.push(bl.to_string());
                }
            }
            listed
        },
        check_spf(resolver, ip, domain, 0),
    );
    SecurityResults { rdns: rdns.0, rdns_pass: rdns.1, dnsbl_listed: dnsbl, spf }
}

// ── App state ───────────────────────────────────────────────────────

struct AppState {
    config: Config,
    resolver: TokioAsyncResolver,
}

// ── HTTP handlers ───────────────────────────────────────────────────

async fn handle_post(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let client_ip = headers.get("cf-connecting-ip")
        .and_then(|v| v.to_str().ok())
        .or_else(|| headers.get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .map(str::trim))
        .unwrap_or("unknown")
        .to_string();

    info!(client_ip = %client_ip, "POST received");

    // ── Auth ──
    let auth = headers.get("x-api-key").and_then(|v| v.to_str().ok()).unwrap_or("");
    if auth != state.config.api_key {
        warn!(client_ip = %client_ip, "AUTH FAILED");
        return (StatusCode::UNAUTHORIZED, Json(json!({"status":"error","error":"Unauthorized"}))).into_response();
    }

    // ── Parse email ──
    let mail_from = extract_address(&body, "From").unwrap_or_else(|| "cloudflare@localhost".into());
    let mail_to = extract_address(&body, "To").unwrap_or_else(|| state.config.smtp_user.clone());
    let msg_id = extract_header(&body, "Message-ID").unwrap_or_else(|| "?".into());
    let sender_domain = mail_from.rsplit_once('@').map(|(_, d)| d.to_string()).unwrap_or_default();

    info!(from = %mail_from, to = %mail_to, msg_id = %msg_id, client_ip = %client_ip, "Processing");

    // ── IP security checks (rDNS, DNSBL, SPF) ──
    if let Ok(ip) = IpAddr::from_str(&client_ip) {
        let checks = run_checks(&state.resolver, ip, &sender_domain).await;

        info!(
            client_ip = %client_ip,
            rdns = ?checks.rdns,
            rdns_pass = checks.rdns_pass,
            dnsbl = ?checks.dnsbl_listed,
            spf = %checks.spf,
            "Security checks"
        );

        if !checks.dnsbl_listed.is_empty() {
            warn!(client_ip = %client_ip, lists = ?checks.dnsbl_listed, "REJECTED: DNSBL");
            return (StatusCode::FORBIDDEN, Json(json!({
                "status": "rejected", "reason": "DNSBL", "blocklists": checks.dnsbl_listed,
            }))).into_response();
        }

        if checks.spf == SpfResult::Fail {
            warn!(client_ip = %client_ip, domain = %sender_domain, "REJECTED: SPF fail");
            return (StatusCode::FORBIDDEN, Json(json!({
                "status": "rejected", "reason": "SPF fail",
            }))).into_response();
        }

        if !checks.rdns_pass {
            warn!(client_ip = %client_ip, "rDNS failed (warning)");
        }
    }

    // ── Forward to Maddy via SMTP ──
    let from_addr = mail_from.parse().unwrap_or_else(|_| "cloudflare@localhost".parse().unwrap());
    let to_addr = mail_to.parse().unwrap_or_else(|_| state.config.smtp_user.parse().unwrap());
    let envelope = match Envelope::new(Some(from_addr), vec![to_addr]) {
        Ok(e) => e,
        Err(e) => {
            error!(error = %e, "Bad envelope");
            return (StatusCode::BAD_REQUEST, Json(json!({"status":"error","error":e.to_string()}))).into_response();
        }
    };

    let result = if state.config.smtp_port == 587 {
        match AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&state.config.smtp_host) {
            Ok(builder) => builder
                .port(state.config.smtp_port)
                .credentials(Credentials::new(state.config.smtp_user.clone(), state.config.smtp_pass.clone()))
                .hello_name(ClientId::Domain(state.config.helo_domain.clone()))
                .build()
                .send_raw(&envelope, &body).await,
            Err(e) => {
                error!(error = %e, "SMTP TLS error");
                return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status":"error","error":e.to_string()}))).into_response();
            }
        }
    } else {
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&state.config.smtp_host)
            .port(state.config.smtp_port)
            .hello_name(ClientId::Domain(state.config.helo_domain.clone()))
            .build()
            .send_raw(&envelope, &body).await
    };

    match result {
        Ok(_) => {
            info!(msg_id = %msg_id, from = %mail_from, to = %mail_to, "Delivered OK");
            (StatusCode::OK, Json(json!({"status":"delivered","from":mail_from,"to":mail_to}))).into_response()
        }
        Err(e) => {
            error!(error = %e, msg_id = %msg_id, "Delivery failed");
            (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status":"error","error":e.to_string()}))).into_response()
        }
    }
}

async fn handle_health() -> Json<Value> {
    Json(json!({"status": "ok"}))
}

// ── Main ────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().json().with_target(false).init();

    let config = Config::from_env();
    let port = config.listen_port;

    info!(
        port = port,
        smtp = %format!("{}:{}", config.smtp_host, config.smtp_port),
        helo = config.helo_domain,
        "SMTP Proxy starting"
    );

    let resolver = TokioAsyncResolver::tokio(ResolverConfig::default(), ResolverOpts::default());
    let state = Arc::new(AppState { config, resolver });

    let app = Router::new()
        .route("/", post(handle_post))
        .route("/health", get(handle_health))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await
        .expect("Failed to bind");
    info!(port = port, "Listening");
    axum::serve(listener, app).await.expect("Server error");
}
