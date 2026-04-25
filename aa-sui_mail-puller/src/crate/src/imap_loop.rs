//! Per-(source, mailbox) IMAP polling loop.
//!
//! Originally intended as IMAP IDLE for sub-second push. async-imap 0.9's IDLE
//! API consumes the Session into a Handle that isn't cleanly reclaimed for
//! subsequent commands, which is awkward for a long-running daemon. Polling is
//! boring but robust: every `poll_fallback_secs`, connect → SELECT → UID SEARCH
//! new → fetch → deliver → disconnect. Latency = cadence (default 300 s).
//! Cadence is tunable per-deploy via sources.json#defaults.poll_fallback_secs.

use anyhow::{anyhow, Context, Result};
use async_imap::{Authenticator, Client, Session};
use futures::StreamExt;
use std::{sync::Arc, time::Duration};
use tokio::net::TcpStream;
use tokio_rustls::{rustls::{ClientConfig, RootCertStore}, TlsConnector};
use tokio_util::compat::{Compat, TokioAsyncReadCompatExt};

use std::env;
use crate::{config::{AuthMethod, Config, Source}, deliver, oauth, state::State};

type ImapStream = Compat<tokio_rustls::client::TlsStream<TcpStream>>;

struct XOAuth2 {
    user: String,
    token: String,
}
impl Authenticator for &XOAuth2 {
    type Response = Vec<u8>;
    fn process(&mut self, _challenge: &[u8]) -> Self::Response {
        format!("user={}\x01auth=Bearer {}\x01\x01", self.user, self.token).into_bytes()
    }
}

fn tls_config() -> ClientConfig {
    let mut root = RootCertStore::empty();
    root.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    ClientConfig::builder()
        .with_root_certificates(root)
        .with_no_client_auth()
}

pub async fn run(src: &Source, mbox: &str, cfg: &Config, state: State) -> Result<()> {
    let interval = Duration::from_secs(cfg.defaults.poll_fallback_secs.max(10));
    tracing::info!(
        source   = %src.id,
        mailbox  = %mbox,
        host     = %src.imap_host,
        cadence  = ?interval,
        "poll loop starting"
    );

    loop {
        match one_cycle(src, mbox, cfg, &state).await {
            Ok(delivered) => {
                if delivered > 0 {
                    tracing::info!(source = %src.id, mailbox = %mbox, delivered, "cycle ok");
                } else {
                    tracing::debug!(source = %src.id, mailbox = %mbox, "cycle ok (no new)");
                }
            }
            Err(e) => tracing::error!(source = %src.id, mailbox = %mbox, error = %e, "cycle failed"),
        }
        tokio::time::sleep(interval).await;
    }
}

async fn one_cycle(src: &Source, mbox: &str, cfg: &Config, state: &State) -> Result<u32> {
    let addr = format!("{}:{}", src.imap_host, src.imap_port);
    let tcp  = TcpStream::connect(&addr).await.with_context(|| format!("tcp {}", addr))?;
    let tls  = TlsConnector::from(Arc::new(tls_config()));
    let dns  = rustls::pki_types::ServerName::try_from(src.imap_host.clone())
        .map_err(|_| anyhow!("invalid DNS name {}", src.imap_host))?;
    let tls_stream = tls.connect(dns, tcp).await.context("TLS handshake")?;

    let client = Client::new(tls_stream.compat());

    // Resolve auth (supports new tagged AuthMethod + legacy `oauth` field).
    let auth_method = src.resolve_auth()?;
    let mut session: Session<ImapStream> = match auth_method {
        AuthMethod::Oauth(oauth_ref) => {
            let access = oauth::fetch(&oauth_ref).await.context("oauth refresh")?;
            let auth = XOAuth2 { user: src.email.clone(), token: access.value };
            client
                .authenticate("XOAUTH2", &auth)
                .await
                .map_err(|(e, _)| anyhow!("XOAUTH2 auth failed: {:?}", e))?
        }
        AuthMethod::AppPassword { password_env } => {
            let pw = env::var(&password_env)
                .with_context(|| format!("env var {} unset (App Password for {})", password_env, src.id))?;
            client
                .login(&src.email, &pw)
                .await
                .map_err(|(e, _)| anyhow!("LOGIN auth failed for {}: {:?}", src.email, e))?
        }
    };

    let select = session.select(mbox).await.with_context(|| format!("SELECT {}", mbox))?;
    let uidvalidity = select.uid_validity.unwrap_or(0) as u32;
    let (prev_uv, prev_uid) = state.get_cursor(&src.id, mbox)?;
    let from_uid = if prev_uv != uidvalidity { 0 } else { prev_uid };

    let count = fetch_and_deliver(&mut session, src, mbox, cfg, state, from_uid, uidvalidity).await?;

    let _ = session.logout().await;
    Ok(count)
}

async fn fetch_and_deliver(
    session: &mut Session<ImapStream>,
    src: &Source,
    mbox: &str,
    cfg: &Config,
    state: &State,
    from_uid: u32,
    uidvalidity: u32,
) -> Result<u32> {
    let query = format!("{}:*", from_uid.saturating_add(1));
    let mut stream = session.uid_fetch(&query, "(UID ENVELOPE BODY.PEEK[])").await?;

    let mut max_uid = from_uid;
    let mut count = 0u32;

    while let Some(fetch_res) = stream.next().await {
        let fetch = fetch_res?;
        let uid = match fetch.uid { Some(u) => u, None => continue };
        if uid <= from_uid { continue; }

        let envelope = fetch.envelope();
        let subject = envelope
            .and_then(|e| e.subject.as_ref())
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_else(|| "(no subject)".into());
        let msg_id = envelope
            .and_then(|e| e.message_id.as_ref())
            .map(|b| String::from_utf8_lossy(b).into_owned());

        let raw = fetch.body().ok_or_else(|| anyhow!("UID {} missing BODY[]", uid))?.to_vec();

        for target_name in &src.targets {
            if let Some(t) = cfg.delivery_targets.get(target_name) {
                match deliver::deliver_raw(
                    target_name, t,
                    &src.deliver_envelope_from,
                    &src.deliver_envelope_to,
                    &subject,
                    &raw,
                ).await {
                    Ok(()) => tracing::info!(source = %src.id, mailbox = %mbox, uid, target = %target_name, "delivered"),
                    Err(e) => tracing::error!(source = %src.id, mailbox = %mbox, uid, target = %target_name, error = ?e, "deliver failed"),
                }
            }
        }

        state.record_delivered(&src.id, mbox, uid, msg_id.as_deref())?;
        if uid > max_uid { max_uid = uid; }
        count += 1;
        if count >= cfg.defaults.fetch_batch { break; }
    }
    drop(stream);

    if max_uid > from_uid {
        state.set_cursor(&src.id, mbox, uidvalidity, max_uid)?;
    }
    Ok(count)
}
