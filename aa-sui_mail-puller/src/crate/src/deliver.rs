//! SMTP submission to local Maddy / Stalwart. One submission per target, so
//! each server's native pipeline (filter/sieve) runs independently.
//!
//! Envelope from/to come from sources.json, not the pulled message's headers
//! — we preserve the message body/headers intact and just re-deliver as a new
//! transaction on port 587/2587.

use anyhow::{Context, Result};
use lettre::{
    address::Address,
    transport::smtp::{
        authentication::Credentials,
        client::{Tls, TlsParameters},
    },
    AsyncSmtpTransport, AsyncTransport, Envelope, Tokio1Executor,
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
    // Forward the original RFC822 message verbatim — preserve every header
    // (From, To, Subject, Message-Id, DKIM-Signature, Received, …) exactly
    // as the upstream provider sent it. Wrapping with Message::builder()
    // would re-encode and corrupt Gmail/Outlook MIME structures.
    //
    // SMTP envelope (MAIL FROM / RCPT TO) is set independently from the
    // headers — that is the whole point of envelope routing.
    let from_addr: Address = envelope_from.parse()
        .with_context(|| format!("parse envelope_from: {}", envelope_from))?;
    let to_addr: Address = envelope_to.parse()
        .with_context(|| format!("parse envelope_to: {}", envelope_to))?;
    let envelope = Envelope::new(Some(from_addr), vec![to_addr])
        .context("build SMTP envelope")?;

    let user = target.resolve_user()?;
    let pass = target.resolve_pass()?;
    let creds = Credentials::new(user, pass);

    // Local-net trust domain: puller connects to Maddy/Stalwart by WG IP
    // (e.g. 10.0.0.3) but their certs are issued for *.diegonmarcos.com.
    // Skip both cert-chain and hostname checks — we're inside the WG mesh,
    // not exposed to the internet.
    let tls = TlsParameters::builder(target.host.clone())
        .dangerous_accept_invalid_certs(true)
        .dangerous_accept_invalid_hostnames(true)
        .build()?;

    let transport: AsyncSmtpTransport<Tokio1Executor> = if target.starttls {
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&target.host)
            .port(target.port)
            .tls(Tls::Required(tls))
            .credentials(creds)
            .build()
    } else {
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&target.host)
            .port(target.port)
            .credentials(creds)
            .build()
    };

    transport.send_raw(&envelope, raw_rfc822).await
        .with_context(|| format!("smtp send to target={} {}:{}", target_name, target.host, target.port))?;
    Ok(())
}
