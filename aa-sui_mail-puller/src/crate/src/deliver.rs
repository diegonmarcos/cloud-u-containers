//! SMTP submission to local Maddy / Stalwart — minimal hand-rolled client.
//!
//! Why hand-rolled and not lettre? lettre 0.11.x's public `Envelope`
//! re-export turned out to be feature-gated in a way that doesn't compose
//! with our minimal feature set (`tokio1 + tokio1-rustls-tls + builder +
//! smtp-transport`), and Message::builder() re-encoded the original RFC822
//! with a `Content-Type: message/rfc822` wrapper that Maddy rejected with
//! "malformed MIME header key". For our tightly-scoped need (one
//! authenticated submission, raw RFC822 forward, STARTTLS over a trusted
//! WG mesh), 80 lines of explicit SMTP is simpler and bulletproof.
//!
//! Flow:  TCP → 220 banner → EHLO → STARTTLS → 220 → TLS upgrade → EHLO
//!     →  AUTH PLAIN → MAIL FROM → RCPT TO → DATA → 354 → raw bytes
//!        (with dot-stuffing + CRLF normalisation) → "\r\n.\r\n" → 250 → QUIT.
//!
//! Envelope FROM/TO come from sources.json (config), independent from the
//! original message's headers — we forward the message body byte-perfect.

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine as _;
use std::sync::Arc;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufStream},
    net::TcpStream,
};
use tokio_rustls::{
    rustls::{
        client::{
            danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
            WebPkiServerVerifier,
        },
        crypto::{ring, CryptoProvider},
        pki_types::{CertificateDer, ServerName, UnixTime},
        ClientConfig, DigitallySignedStruct, SignatureScheme,
    },
    TlsConnector,
};

use crate::config::SmtpTarget;

pub async fn deliver_raw(
    target_name: &str,
    target: &SmtpTarget,
    envelope_from: &str,
    envelope_to: &str,
    _subject_hint: &str,
    raw_rfc822: &[u8],
) -> Result<()> {
    let user = target.resolve_user()?;
    let pass = target.resolve_pass()?;

    let addr = format!("{}:{}", target.host, target.port);
    let tcp = TcpStream::connect(&addr).await
        .with_context(|| format!("smtp connect {}", addr))?;

    // Plaintext SMTP banner + EHLO + STARTTLS dance.
    let mut s = BufStream::new(tcp);
    expect_code(&mut s, 220, "banner").await?;
    write_line(&mut s, "EHLO mail-puller").await?;
    expect_code(&mut s, 250, "EHLO/1").await?;

    if target.starttls {
        write_line(&mut s, "STARTTLS").await?;
        expect_code(&mut s, 220, "STARTTLS").await?;
    }

    // Recover the underlying TcpStream and upgrade to TLS.
    let tcp = s.into_inner();
    let connector = TlsConnector::from(Arc::new(tls_client_config()));
    let dns = ServerName::try_from(target.host.clone())
        .map_err(|_| anyhow!("invalid SNI hostname: {}", target.host))?;
    let tls = connector.connect(dns, tcp).await
        .with_context(|| format!("TLS handshake to {}", target.host))?;
    let mut s = BufStream::new(tls);

    write_line(&mut s, "EHLO mail-puller").await?;
    expect_code(&mut s, 250, "EHLO/2").await?;

    // AUTH PLAIN: \0username\0password (RFC 4616), base64.
    let mut auth = Vec::with_capacity(2 + user.len() + pass.len());
    auth.push(0u8);
    auth.extend_from_slice(user.as_bytes());
    auth.push(0u8);
    auth.extend_from_slice(pass.as_bytes());
    let auth_b64 = base64::engine::general_purpose::STANDARD.encode(&auth);
    write_line(&mut s, &format!("AUTH PLAIN {}", auth_b64)).await?;
    expect_code(&mut s, 235, "AUTH").await?;

    write_line(&mut s, &format!("MAIL FROM:<{}>", envelope_from)).await?;
    expect_code(&mut s, 250, "MAIL FROM").await?;
    write_line(&mut s, &format!("RCPT TO:<{}>", envelope_to)).await?;
    expect_code(&mut s, 250, "RCPT TO").await?;

    write_line(&mut s, "DATA").await?;
    expect_code(&mut s, 354, "DATA").await?;

    // Stream the raw RFC822, normalising LF→CRLF and dot-stuffing per RFC 5321 §4.5.2.
    let normalised = normalise_for_data(raw_rfc822);
    s.write_all(&normalised).await?;
    if !normalised.ends_with(b"\r\n") {
        s.write_all(b"\r\n").await?;
    }
    s.write_all(b".\r\n").await?;
    s.flush().await?;
    expect_code(&mut s, 250, "end-of-DATA").await?;

    write_line(&mut s, "QUIT").await?;
    // 221 expected; ignore failure here — message is delivered.
    let _ = read_response(&mut s).await;
    Ok(())
}

// ── Helpers ────────────────────────────────────────────────────────────

async fn write_line<S>(s: &mut BufStream<S>, line: &str) -> Result<()>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    s.write_all(line.as_bytes()).await?;
    s.write_all(b"\r\n").await?;
    s.flush().await?;
    Ok(())
}

/// Read one SMTP response (single or multi-line). Returns (code, full_text).
async fn read_response<S>(s: &mut BufStream<S>) -> Result<(u16, String)>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    let mut buf = String::new();
    let mut code: u16 = 0;
    loop {
        let mut line = String::new();
        let n = read_until_crlf(s, &mut line).await?;
        if n == 0 {
            bail!("smtp: unexpected EOF");
        }
        if line.len() < 4 {
            bail!("smtp: short response: {:?}", line);
        }
        let line_code: u16 = line[..3].parse().context("smtp: parse code")?;
        if code == 0 {
            code = line_code;
        }
        buf.push_str(&line);
        // Continuation: 4th char is '-'; final line: ' '.
        if line.as_bytes()[3] == b' ' {
            return Ok((code, buf));
        }
    }
}

async fn read_until_crlf<S>(s: &mut BufStream<S>, out: &mut String) -> Result<usize>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    let mut total = 0;
    loop {
        let mut byte = [0u8; 1];
        let n = s.read(&mut byte).await?;
        if n == 0 { return Ok(total); }
        total += n;
        out.push(byte[0] as char);
        if out.ends_with("\r\n") { return Ok(total); }
        if total > 4096 { bail!("smtp: response line too long"); }
    }
}

async fn expect_code<S>(s: &mut BufStream<S>, want: u16, ctx: &str) -> Result<()>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    let (got, body) = read_response(s).await
        .with_context(|| format!("smtp: read response after {}", ctx))?;
    if got != want {
        bail!("smtp: expected {} after {}, got {}: {}", want, ctx, got, body.trim_end());
    }
    Ok(())
}

/// LF→CRLF normalisation + dot-stuffing for SMTP DATA payload.
fn normalise_for_data(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len() + input.len() / 32);
    let mut prev: u8 = 0;
    let mut at_line_start = true;
    for &b in input {
        if b == b'\n' && prev != b'\r' {
            out.push(b'\r');
        }
        if at_line_start && b == b'.' {
            out.push(b'.');  // double leading dot
        }
        out.push(b);
        at_line_start = b == b'\n';
        prev = b;
    }
    out
}

// ── TLS config: trust local-net certs (WG mesh, *.diegonmarcos.com vs IP) ─

fn tls_client_config() -> ClientConfig {
    // Inside the WG mesh we connect by IP but the cert is for *.diegonmarcos.com.
    // Skip cert chain + hostname verification — same trust assumption as the
    // pre-rewrite lettre TlsParameters.
    let provider = Arc::new(ring::default_provider());
    let _ = CryptoProvider::install_default(ring::default_provider());
    let _ = WebPkiServerVerifier::builder_with_provider(
        Arc::new(rustls::RootCertStore::empty()),
        provider.clone(),
    );

    ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("rustls: protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoVerify))
        .with_no_client_auth()
}

#[derive(Debug)]
struct NoVerify;

impl ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ED25519,
        ]
    }
}
