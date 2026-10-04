//! End-to-end mail round-trip: SMTP send no-reply@ → me@, then IMAP poll me@ inbox.
//! IMAP is implemented raw over tokio-rustls (only a handful of verbs needed),
//! avoiding openssl-sys.

use crate::config::EmailConfig;
use lettre::message::Message;
use lettre::transport::smtp::authentication::Credentials;
use lettre::transport::smtp::client::{Tls, TlsParameters};
use lettre::{AsyncSmtpTransport, AsyncTransport, Tokio1Executor};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde::Serialize;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_rustls::TlsConnector;

#[derive(Debug, Serialize, Clone)]
pub struct EmailResult {
    pub subject: String,
    pub outbound_ok: bool,
    pub outbound_ms: u64,
    pub inbound_ok: bool,
    pub inbound_ms: u64,
    pub error: Option<String>,
}

pub async fn run(cfg: &EmailConfig, token: &str) -> EmailResult {
    let subject = format!("{} {}", cfg.subject_prefix, token);
    let noreply_pw = std::env::var("NOREPLY_PASSWORD").ok();
    let me_pw = std::env::var("ME_PASSWORD").ok();

    if noreply_pw.is_none() || me_pw.is_none() {
        return EmailResult {
            subject,
            outbound_ok: false,
            outbound_ms: 0,
            inbound_ok: false,
            inbound_ms: 0,
            error: Some(
                "NOREPLY_PASSWORD and/or ME_PASSWORD env not set — email E2E skipped".into(),
            ),
        };
    }

    let noreply_pw = noreply_pw.unwrap();
    let me_pw = me_pw.unwrap();

    // Kick off inbound poll FIRST so we start watching before outbound hits the wire.
    let imap_host = cfg.imap.host.clone();
    let imap_port = cfg.imap.port;
    let imap_user = cfg.imap.username.clone();
    let subject_needle = subject.clone();
    let timeout = Duration::from_secs(cfg.timeout_secs);
    let poll_interval = Duration::from_millis(cfg.poll_interval_ms);

    let inbound = tokio::spawn(async move {
        poll_inbox(
            &imap_host,
            imap_port,
            &imap_user,
            &me_pw,
            &subject_needle,
            timeout,
            poll_interval,
        )
        .await
    });

    let outbound_start = Instant::now();
    let outbound = send_smtp(cfg, &noreply_pw, &subject, token).await;
    let outbound_ms = outbound_start.elapsed().as_millis() as u64;

    let outbound_ok = outbound.is_ok();
    let mut error: Option<String> = outbound.err().map(|e| e.to_string());

    let inbound_start = Instant::now();
    let inbound_res = match inbound.await {
        Ok(r) => r,
        Err(e) => Err(anyhow::anyhow!("imap task panicked: {}", e)),
    };
    let inbound_ms = inbound_start.elapsed().as_millis() as u64;
    let inbound_ok = inbound_res.is_ok();
    if let Err(e) = inbound_res {
        error = Some(match error {
            Some(prev) => format!("{} | imap: {}", prev, e),
            None => format!("imap: {}", e),
        });
    }

    EmailResult {
        subject,
        outbound_ok,
        outbound_ms,
        inbound_ok,
        inbound_ms,
        error,
    }
}

async fn send_smtp(
    cfg: &EmailConfig,
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
        .build()?;
    let mailer: AsyncSmtpTransport<Tokio1Executor> =
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&cfg.smtp.host)
            .port(cfg.smtp.port)
            .tls(Tls::Required(tls))
            .credentials(Credentials::new(
                cfg.smtp.username.clone(),
                noreply_pw.to_string(),
            ))
            .build();

    mailer.send(msg).await?;
    Ok(())
}

// ── Raw IMAP over tokio-rustls ────────────────────────────────────

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
                eprintln!("[url-health] imap transient error: {}", e);
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
    // rustls 0.23 requires an installed CryptoProvider.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertVerify))
        .with_no_client_auth();
    let connector = TlsConnector::from(Arc::new(config));

    let tcp = tokio::net::TcpStream::connect((host, port)).await?;
    let dns_name = ServerName::try_from(host.to_string())?;
    let mut stream = connector.connect(dns_name, tcp).await?;

    // IMAP greeting
    let mut buf = Vec::new();
    read_until_crlf(&mut stream, &mut buf).await?;

    // LOGIN a1 ...
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

    // SELECT INBOX
    stream.write_all(b"a2 SELECT INBOX\r\n").await?;
    let _ = read_response(&mut stream, "a2").await?;

    // SEARCH HEADER Subject "<needle>"
    let search_cmd = format!("a3 SEARCH HEADER Subject \"{}\"\r\n", subject_needle);
    stream.write_all(search_cmd.as_bytes()).await?;
    let search_resp = read_response(&mut stream, "a3").await?;

    // Parse "* SEARCH 1 2 3" → uid list
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

    // Delete + expunge
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

/// Read lines until a tagged response (e.g. "a1 OK", "a1 NO", "a1 BAD") appears.
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
