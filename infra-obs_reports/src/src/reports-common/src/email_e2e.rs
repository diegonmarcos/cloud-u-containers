//! Shared end-to-end mail round-trip: SMTP send → IMAP poll for arrival.
//! Raw IMAP over tokio-rustls (no openssl-sys).
//!
//! Used by:
//!   - cloud-url-health-report (fast E2E probe)
//!   - cloud-health-full-2     (L11 — replaces former Resend integration)

use crate::context::find_cloud_data_file;
use lettre::message::Message;
use lettre::transport::smtp::authentication::Credentials;
use lettre::transport::smtp::client::{Tls, TlsParameters};
use lettre::{AsyncSmtpTransport, AsyncTransport, Tokio1Executor};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_rustls::TlsConnector;

#[derive(Debug, Deserialize, Clone)]
pub struct MailEndpoint {
    pub host: String,
    pub port: u16,
    pub username: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct EmailE2EConfig {
    pub smtp: MailEndpoint,
    pub imap: MailEndpoint,
    pub timeout_secs: u64,
    pub poll_interval_ms: u64,
    pub subject_prefix: String,
    /// JMAP (Stalwart) landing endpoint. host=jmap.diegonmarcos.com, port=443,
    /// username=me@…; Basic-auths with ME_PASSWORD. None ⇒ JMAP leg skipped.
    #[serde(default)]
    pub jmap: Option<MailEndpoint>,
    /// mail-API liveness URL (http-to-smtp-proxy-api). None ⇒ leg skipped.
    #[serde(default)]
    pub api_health_url: Option<String>,
    /// mail-MCP liveness URL (mcp.diegonmarcos.com/mail-mcp). None ⇒ leg skipped.
    #[serde(default)]
    pub mcp_health_url: Option<String>,
}

/// Load `email` block — migrated to build-reports.json:.url_health.email;
/// legacy cloud-data-url-health.json fallback during migration window.
pub fn load_config() -> anyhow::Result<EmailE2EConfig> {
    if let Some(uh) = crate::context::load_build_reports_section("url_health") {
        if let Some(email_block) = uh.get("email").cloned() {
            return Ok(serde_json::from_value(email_block)?);
        }
    }
    let path = find_cloud_data_file("cloud-data-url-health.json")
        .ok_or_else(|| anyhow::anyhow!("neither build-reports.json:.url_health.email nor cloud-data-url-health.json found"))?;
    let raw = std::fs::read(&path)?;
    let v: serde_json::Value = serde_json::from_slice(&raw)?;
    let email_block = v.get("email").cloned()
        .ok_or_else(|| anyhow::anyhow!("missing 'email' block in {}", path.display()))?;
    let cfg: EmailE2EConfig = serde_json::from_value(email_block)?;
    Ok(cfg)
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct EmailResult {
    pub subject: String,
    pub outbound_ok: bool,
    pub outbound_ms: u64,
    pub inbound_ok: bool, // IMAP (Maddy) landing
    pub inbound_ms: u64,
    pub jmap_ok: bool,    // JMAP (Stalwart) landing — false if cfg.jmap None
    pub jmap_ms: u64,
    pub jmap_checked: bool,
    pub api_ok: bool,     // mail-API (http-to-smtp-proxy-api) liveness
    pub api_checked: bool,
    pub mcp_ok: bool,     // mail-MCP liveness
    pub mcp_checked: bool,
    pub error: Option<String>,
}

impl EmailResult {
    /// Green only when every CHECKED leg passed (per-leg reported; full health = green).
    pub fn all_ok(&self) -> bool {
        self.outbound_ok
            && self.inbound_ok
            && (!self.jmap_checked || self.jmap_ok)
            && (!self.api_checked || self.api_ok)
            && (!self.mcp_checked || self.mcp_ok)
    }
}

fn push_err(error: &mut Option<String>, leg: &str, e: String) {
    *error = Some(match error.take() {
        Some(p) => format!("{} | {}: {}", p, leg, e),
        None => format!("{}: {}", leg, e),
    });
}

pub async fn run(cfg: &EmailE2EConfig, token: &str) -> EmailResult {
    let subject = format!("{} {}", cfg.subject_prefix, token);
    let noreply_pw = std::env::var("NOREPLY_PASSWORD").ok();
    let me_pw = std::env::var("ME_PASSWORD").ok();

    if noreply_pw.is_none() || me_pw.is_none() {
        return EmailResult {
            subject,
            error: Some(
                "NOREPLY_PASSWORD and/or ME_PASSWORD env not set — email E2E skipped".into(),
            ),
            ..Default::default()
        };
    }

    let noreply_pw = noreply_pw.unwrap();
    let me_pw = me_pw.unwrap();
    let timeout = Duration::from_secs(cfg.timeout_secs);
    let poll_interval = Duration::from_millis(cfg.poll_interval_ms);

    // ── inbound IMAP poll (Maddy) ──
    let imap_host = cfg.imap.host.clone();
    let imap_port = cfg.imap.port;
    let imap_user = cfg.imap.username.clone();
    let imap_pw = me_pw.clone();
    let imap_needle = subject.clone();
    let inbound = tokio::spawn(async move {
        poll_inbox(
            &imap_host, imap_port, &imap_user, &imap_pw, &imap_needle, timeout, poll_interval,
        )
        .await
    });

    // ── inbound JMAP poll (Stalwart) — only if declared ──
    let jmap_task = cfg.jmap.clone().map(|jm| {
        let pw = me_pw.clone();
        let needle = subject.clone();
        tokio::spawn(async move {
            poll_jmap(&jm.host, jm.port, &jm.username, &pw, &needle, timeout, poll_interval).await
        })
    });

    // ── outbound SMTP send (dual-delivers Maddy + Stalwart + g-workspace) ──
    let outbound_start = Instant::now();
    let outbound = send_smtp(cfg, &noreply_pw, &subject, token).await;
    let outbound_ms = outbound_start.elapsed().as_millis() as u64;
    let outbound_ok = outbound.is_ok();
    let mut error: Option<String> = outbound.err().map(|e| e.to_string());

    // IMAP result
    let imap_start = Instant::now();
    let inbound_res = match inbound.await {
        Ok(r) => r,
        Err(e) => Err(anyhow::anyhow!("imap task panicked: {}", e)),
    };
    let inbound_ms = imap_start.elapsed().as_millis() as u64;
    let inbound_ok = inbound_res.is_ok();
    if let Err(e) = inbound_res {
        push_err(&mut error, "imap", e.to_string());
    }

    // JMAP result
    let (mut jmap_ok, mut jmap_ms, mut jmap_checked) = (false, 0u64, false);
    if let Some(t) = jmap_task {
        jmap_checked = true;
        let start = Instant::now();
        let res = match t.await {
            Ok(r) => r,
            Err(e) => Err(anyhow::anyhow!("jmap task panicked: {}", e)),
        };
        jmap_ms = start.elapsed().as_millis() as u64;
        jmap_ok = res.is_ok();
        if let Err(e) = res {
            push_err(&mut error, "jmap", e.to_string());
        }
    }

    // mail-API liveness
    let (mut api_ok, mut api_checked) = (false, false);
    if let Some(url) = &cfg.api_health_url {
        api_checked = true;
        match check_liveness(url).await {
            Ok(()) => api_ok = true,
            Err(e) => push_err(&mut error, "mail-api", e.to_string()),
        }
    }

    // mail-MCP liveness
    let (mut mcp_ok, mut mcp_checked) = (false, false);
    if let Some(url) = &cfg.mcp_health_url {
        mcp_checked = true;
        match check_liveness(url).await {
            Ok(()) => mcp_ok = true,
            Err(e) => push_err(&mut error, "cloud-mail-mcp", e.to_string()),
        }
    }

    EmailResult {
        subject,
        outbound_ok,
        outbound_ms,
        inbound_ok,
        inbound_ms,
        jmap_ok,
        jmap_ms,
        jmap_checked,
        api_ok,
        api_checked,
        mcp_ok,
        mcp_checked,
        error,
    }
}

/// JMAP landing poll: session (Basic auth) → Email/query filtered by subject.
async fn poll_jmap(
    host: &str,
    port: u16,
    username: &str,
    password: &str,
    subject_needle: &str,
    total_timeout: Duration,
    poll_interval: Duration,
) -> anyhow::Result<()> {
    let base = if port == 443 {
        format!("https://{}", host)
    } else {
        format!("https://{}:{}", host, port)
    };
    // WG-direct (10.0.0.3:2443) like the IMAP leg: the public domain
    // jmap.diegonmarcos.com is unreachable/slow from the CI runner. Connecting by
    // WG IP means the cert won't match → accept invalid certs (same as send_smtp).
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .danger_accept_invalid_certs(true)
        .build()?;

    // JMAP session — discover apiUrl + the mail account id.
    let session: serde_json::Value = client
        .get(format!("{}/.well-known/jmap", base))
        .basic_auth(username, Some(password))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let api_url_raw = session["apiUrl"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("jmap session: no apiUrl"))?;
    // The session may return an absolute apiUrl on the PUBLIC domain
    // (jmap.diegonmarcos.com), which is unreachable from the CI runner. Keep only
    // the path and re-base it onto the WG endpoint we reached the session on.
    let api_path = if api_url_raw.starts_with("http") {
        reqwest::Url::parse(api_url_raw)
            .ok()
            .map(|u| u.path().to_string())
            .unwrap_or_else(|| api_url_raw.to_string())
    } else {
        api_url_raw.to_string()
    };
    let api_url = format!("{}{}", base, api_path);
    let account = session["primaryAccounts"]["urn:ietf:params:jmap:mail"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("jmap session: no mail account"))?
        .to_string();

    // Stalwart's JMAP `subject` filter is FTS-tokenized (splits on hyphens/spaces),
    // so the full bracketed subject "[url-health-e2e] url-e2e-<uuid>" never matches
    // as a phrase. Filter on the longest clean alphanumeric token (the unique id
    // fragment), which IS a single FTS token. (The IMAP leg uses substring SEARCH,
    // so it is unaffected and keeps using the full subject.)
    let fts_token = subject_needle
        .split(|c: char| !c.is_ascii_alphanumeric())
        .max_by_key(|t| t.len())
        .filter(|t| !t.is_empty())
        .unwrap_or(subject_needle);

    let deadline = Instant::now() + total_timeout;
    while Instant::now() < deadline {
        let body = serde_json::json!({
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [["Email/query",
                {"accountId": account, "filter": {"subject": fts_token}, "limit": 5}, "q"]]
        });
        match client
            .post(&api_url)
            .basic_auth(username, Some(password))
            .json(&body)
            .send()
            .await
        {
            Ok(r) => {
                let v: serde_json::Value = r.error_for_status()?.json().await?;
                let found = v["methodResponses"][0][1]["ids"]
                    .as_array()
                    .map(|a| !a.is_empty())
                    .unwrap_or(false);
                if found {
                    return Ok(());
                }
            }
            Err(e) => eprintln!("[email_e2e] jmap transient error: {}", e),
        }
        tokio::time::sleep(poll_interval).await;
    }
    anyhow::bail!(
        "jmap timeout ({}s) waiting for subject={:?}",
        total_timeout.as_secs(),
        subject_needle
    )
}

/// Liveness: any response that isn't a 5xx means the service is up (401/403/404/
/// 302 are "alive" — auth gate / no-root-handler). 5xx or connect error = down.
async fn check_liveness(url: &str) -> anyhow::Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let status = client.get(url).send().await?.status().as_u16();
    if status < 500 {
        Ok(())
    } else {
        anyhow::bail!("status {}", status)
    }
}

async fn send_smtp(
    cfg: &EmailE2EConfig,
    noreply_pw: &str,
    subject: &str,
    token: &str,
) -> anyhow::Result<()> {
    let msg = Message::builder()
        .from(cfg.smtp.username.parse()?)
        .to(cfg.imap.username.parse()?)
        .subject(subject)
        .body(format!(
            "url-health E2E probe\ntoken: {}\nsent: {}\n",
            token,
            chrono::Utc::now().to_rfc3339(),
        ))?;

    let tls = TlsParameters::builder(cfg.smtp.host.clone())
        .dangerous_accept_invalid_certs(true)
        // We connect by WG IP (10.0.0.3); Maddy's cert is for *.diegonmarcos.com,
        // so the SAN won't match the IP. WG is the trust boundary → also skip
        // hostname verification (accept_invalid_certs alone keeps SAN checking).
        .dangerous_accept_invalid_hostnames(true)
        .build()?;
    // Port 465 = implicit TLS (SMTPS) → Tls::Wrapper. Port 587 = STARTTLS → Tls::Required.
    // Using Required on 465 makes lettre wait for a plaintext SMTP banner while Maddy
    // immediately starts a TLS handshake → "incomplete response" + a multi-minute hang.
    let tls_mode = if cfg.smtp.port == 465 {
        Tls::Wrapper(tls)
    } else {
        Tls::Required(tls)
    };
    let mailer: AsyncSmtpTransport<Tokio1Executor> =
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&cfg.smtp.host)
            .port(cfg.smtp.port)
            .tls(tls_mode)
            .credentials(Credentials::new(
                cfg.smtp.username.clone(),
                noreply_pw.to_string(),
            ))
            .build();

    mailer.send(msg).await?;
    Ok(())
}

#[derive(Debug)]
struct NoCertVerify;

impl ServerCertVerifier for NoCertVerify {
    fn verify_server_cert(
        &self,
        _end: &CertificateDer<'_>,
        _ints: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _msg: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _msg: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ED25519,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
        ]
    }
}

async fn poll_inbox(
    host: &str,
    port: u16,
    username: &str,
    password: &str,
    subject_needle: &str,
    total_timeout: Duration,
    poll_interval: Duration,
) -> anyhow::Result<()> {
    let deadline = Instant::now() + total_timeout;
    while Instant::now() < deadline {
        match poll_once(host, port, username, password, subject_needle).await {
            Ok(true) => return Ok(()),
            Ok(false) => tokio::time::sleep(poll_interval).await,
            Err(e) => {
                eprintln!("[email_e2e] imap transient error: {}", e);
                tokio::time::sleep(poll_interval).await;
            }
        }
    }
    Err(anyhow::anyhow!(
        "timeout ({}s) waiting for subject={:?}",
        total_timeout.as_secs(),
        subject_needle
    ))
}

async fn poll_once(
    host: &str,
    port: u16,
    username: &str,
    password: &str,
    subject_needle: &str,
) -> anyhow::Result<bool> {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertVerify))
        .with_no_client_auth();
    let connector = TlsConnector::from(Arc::new(config));

    let tcp = tokio::net::TcpStream::connect((host, port)).await?;
    let dns_name = ServerName::try_from(host.to_string())?;
    let mut stream = connector.connect(dns_name, tcp).await?;

    let mut buf = Vec::new();
    read_until_crlf(&mut stream, &mut buf).await?;

    let login_cmd = format!(
        "a1 LOGIN \"{}\" \"{}\"\r\n",
        username.replace('"', "\\\""),
        password.replace('"', "\\\"")
    );
    stream.write_all(login_cmd.as_bytes()).await?;
    let resp = read_response(&mut stream, "a1").await?;
    if !resp.contains("a1 OK") {
        anyhow::bail!("login failed: {}", resp.lines().next().unwrap_or(""));
    }

    stream.write_all(b"a2 SELECT INBOX\r\n").await?;
    let _ = read_response(&mut stream, "a2").await?;

    let search_cmd = format!("a3 SEARCH HEADER Subject \"{}\"\r\n", subject_needle);
    stream.write_all(search_cmd.as_bytes()).await?;
    let search_resp = read_response(&mut stream, "a3").await?;

    let mut uids: Vec<String> = Vec::new();
    for line in search_resp.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("* SEARCH") {
            for t in rest.split_whitespace() {
                if t.parse::<u32>().is_ok() {
                    uids.push(t.to_string());
                }
            }
        }
    }

    if uids.is_empty() {
        let _ = stream.write_all(b"a4 LOGOUT\r\n").await;
        let _ = read_response(&mut stream, "a4").await;
        return Ok(false);
    }

    let set = uids.join(",");
    let store_cmd = format!("a4 STORE {} +FLAGS (\\Deleted)\r\n", set);
    stream.write_all(store_cmd.as_bytes()).await?;
    let _ = read_response(&mut stream, "a4").await;

    stream.write_all(b"a5 EXPUNGE\r\n").await?;
    let _ = read_response(&mut stream, "a5").await;

    stream.write_all(b"a6 LOGOUT\r\n").await?;
    let _ = read_response(&mut stream, "a6").await;

    Ok(true)
}

async fn read_until_crlf<R: AsyncReadExt + Unpin>(
    stream: &mut R,
    buf: &mut Vec<u8>,
) -> anyhow::Result<()> {
    let mut byte = [0u8; 1];
    loop {
        let n = stream.read(&mut byte).await?;
        if n == 0 {
            anyhow::bail!("eof");
        }
        buf.push(byte[0]);
        if buf.ends_with(b"\r\n") {
            return Ok(());
        }
        if buf.len() > 65536 {
            anyhow::bail!("response too long");
        }
    }
}

async fn read_response<R: AsyncReadExt + Unpin>(
    stream: &mut R,
    tag: &str,
) -> anyhow::Result<String> {
    let mut acc = Vec::new();
    loop {
        let mut line = Vec::new();
        read_until_crlf(stream, &mut line).await?;
        let text = String::from_utf8_lossy(&line).to_string();
        acc.push(text.clone());
        let trimmed = text.trim_start();
        if trimmed.starts_with(&format!("{} OK", tag))
            || trimmed.starts_with(&format!("{} NO", tag))
            || trimmed.starts_with(&format!("{} BAD", tag))
        {
            break;
        }
        if acc.len() > 1024 {
            anyhow::bail!("response too long (>1024 lines)");
        }
    }
    Ok(acc.concat())
}
