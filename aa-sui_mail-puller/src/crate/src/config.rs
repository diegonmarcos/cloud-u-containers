//! Config loader — reads sources.json + expands `*_env` references from the
//! process environment (injected by `.secrets` → docker env_file).

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::{collections::HashMap, env, fs, path::PathBuf};

#[derive(Deserialize, Debug, Clone)]
pub struct Defaults {
    pub idle_refresh_secs: u64,
    pub poll_fallback_secs: u64,
    pub reconnect_backoff_secs: Vec<u64>,
    pub fetch_batch: u32,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SmtpTarget {
    pub host: String,
    pub port: u16,
    pub starttls: bool,
    pub user_env: String,
    pub pass_env: String,
}

impl SmtpTarget {
    pub fn resolve_user(&self) -> Result<String> {
        env::var(&self.user_env).with_context(|| format!("env var {} unset", self.user_env))
    }
    pub fn resolve_pass(&self) -> Result<String> {
        env::var(&self.pass_env).with_context(|| format!("env var {} unset", self.pass_env))
    }
}

#[derive(Deserialize, Debug, Clone)]
pub struct OAuthRef {
    pub client_id_env:     String,
    pub client_secret_env: String,
    pub refresh_token_env: String,
    pub token_url:         String,
    #[serde(default)]
    pub scope:             Option<String>,
}

/// New tagged auth field — supports both OAuth (Gmail/Outlook future-proof) and
/// plain App Password (Gmail "App passwords", IMAP LOGIN). Preferred over the
/// legacy top-level `oauth: {…}` field, which is kept for backward compat with
/// existing sources.json files.
#[derive(Deserialize, Debug, Clone)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum AuthMethod {
    Oauth(OAuthRef),
    AppPassword { password_env: String },
}

#[derive(Deserialize, Debug, Clone)]
pub struct Source {
    pub id: String,
    pub provider: String,
    pub imap_host: String,
    pub imap_port: u16,
    pub email: String,
    pub mailboxes: Vec<String>,
    /// New (preferred) — `{ "method": "oauth"|"app_password", … }`.
    #[serde(default)]
    pub auth: Option<AuthMethod>,
    /// Legacy — promoted to `AuthMethod::Oauth` if `auth` is absent.
    #[serde(default)]
    pub oauth: Option<OAuthRef>,
    pub deliver_envelope_from: String,
    pub deliver_envelope_to:   String,
    pub targets: Vec<String>,
}

impl Source {
    /// Resolve the effective auth method, normalizing legacy `oauth` → tagged enum.
    pub fn resolve_auth(&self) -> Result<AuthMethod> {
        if let Some(a) = &self.auth {
            return Ok(a.clone());
        }
        if let Some(o) = &self.oauth {
            return Ok(AuthMethod::Oauth(o.clone()));
        }
        Err(anyhow!(
            "source {}: neither `auth` nor legacy `oauth` field is set",
            self.id
        ))
    }
}

#[derive(Deserialize, Debug, Clone)]
pub struct Raw {
    pub defaults:         Defaults,
    pub delivery_targets: HashMap<String, SmtpTarget>,
    pub sources:          Vec<Source>,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub defaults:         Defaults,
    pub delivery_targets: HashMap<String, SmtpTarget>,
    pub sources:          Vec<Source>,
    pub state_db:         PathBuf,
}

pub fn load() -> Result<Config> {
    let path = env::var("SOURCES_FILE").unwrap_or_else(|_| "/etc/mail-puller/sources.json".into());
    let state_db = env::var("STATE_DB").unwrap_or_else(|_| "/var/lib/mail-puller/state.db".into());
    let bytes = fs::read(&path).with_context(|| format!("read {}", path))?;
    let raw: Raw = serde_json::from_slice(&bytes).context("parse sources.json")?;

    // Pre-validate target refs.
    for s in &raw.sources {
        for t in &s.targets {
            if !raw.delivery_targets.contains_key(t) {
                return Err(anyhow!("source {} references unknown target {}", s.id, t));
            }
        }
    }

    Ok(Config {
        defaults: raw.defaults,
        delivery_targets: raw.delivery_targets,
        sources: raw.sources,
        state_db: state_db.into(),
    })
}
