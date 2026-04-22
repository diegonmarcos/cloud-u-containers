//! OAuth2 refresh-token → access-token exchange.
//!
//! Google + Microsoft both accept the same RFC-6749 "refresh_token" grant at
//! their respective token URLs. The access_token is handed to `async-imap` as
//! the SASL XOAUTH2 bearer.

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::{env, time::{Duration, Instant}};

use crate::config::OAuthRef;

#[derive(Deserialize)]
struct TokenResp {
    access_token: String,
    expires_in:   u64,
}

#[derive(Debug, Clone)]
pub struct AccessToken {
    pub value:   String,
    pub expires: Instant,
}

impl AccessToken {
    pub fn valid(&self) -> bool {
        // Refresh 60s before expiry.
        self.expires > Instant::now() + Duration::from_secs(60)
    }
}

pub async fn fetch(oauth: &OAuthRef) -> Result<AccessToken> {
    let client_id     = env::var(&oauth.client_id_env)
        .with_context(|| format!("env {} unset", oauth.client_id_env))?;
    let client_secret = env::var(&oauth.client_secret_env)
        .with_context(|| format!("env {} unset", oauth.client_secret_env))?;
    let refresh_token = env::var(&oauth.refresh_token_env)
        .with_context(|| format!("env {} unset", oauth.refresh_token_env))?;

    let mut form: Vec<(&str, &str)> = vec![
        ("grant_type",    "refresh_token"),
        ("client_id",     &client_id),
        ("client_secret", &client_secret),
        ("refresh_token", &refresh_token),
    ];
    if let Some(s) = &oauth.scope {
        form.push(("scope", s));
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()?;

    let resp = client.post(&oauth.token_url).form(&form).send().await
        .with_context(|| format!("POST {}", oauth.token_url))?;
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        return Err(anyhow!("token endpoint {} returned {}: {}", oauth.token_url, status, text));
    }
    let parsed: TokenResp = serde_json::from_str(&text)
        .with_context(|| format!("parse token response: {}", text))?;

    Ok(AccessToken {
        value:   parsed.access_token,
        expires: Instant::now() + Duration::from_secs(parsed.expires_in),
    })
}

/// Build SASL XOAUTH2 payload per RFC 7628.
pub fn xoauth2_payload(user: &str, access_token: &str) -> String {
    format!("user={}\x01auth=Bearer {}\x01\x01", user, access_token)
}
