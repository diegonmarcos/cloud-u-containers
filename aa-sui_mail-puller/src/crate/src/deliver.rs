//! SMTP submission to local Maddy / Stalwart. One submission per target, so
//! each server's native pipeline (filter/sieve) runs independently.
//!
//! Envelope from/to come from sources.json, not the pulled message's headers
//! — we preserve the message body/headers intact and just re-deliver as a new
//! transaction on port 587/2587.

use anyhow::{Context, Result};
use lettre::{
    message::header::ContentType,
    transport::smtp::{
        authentication::Credentials,
        client::{Tls, TlsParameters},
    },
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
};

use crate::config::SmtpTarget;

pub async fn deliver_raw(
    target_name: &str,
    target: &SmtpTarget,
    envelope_from: &str,
    envelope_to: &str,
    subject_hint: &str,
    raw_rfc822: &[u8],
) -> Result<()> {
    // Build envelope; body is the raw RFC822 bytes from the source server.
    // lettre's builder needs a Subject header; reuse what we parsed, falling
    // back to a marker so local sorters still classify.
    let msg = Message::builder()
        .from(envelope_from.parse()?)
        .to(envelope_to.parse()?)
        .subject(subject_hint)
        .header(ContentType::parse("message/rfc822")?)
        .body(raw_rfc822.to_vec())
        .context("build lettre message")?;

    let user = target.resolve_user()?;
    let pass = target.resolve_pass()?;
    let creds = Credentials::new(user, pass);

    let tls = TlsParameters::builder(target.host.clone())
        .dangerous_accept_invalid_certs(true) // local-net trust domain
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

    transport.send(msg).await
        .with_context(|| format!("smtp send to target={} {}:{}", target_name, target.host, target.port))?;
    Ok(())
}
