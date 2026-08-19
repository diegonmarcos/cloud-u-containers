//! Probe public URLs (caddy-routed) with bearer token.
//! Source: `build-caddy.json` — merges `.routes[]`, `public_A_mcp`,
//! `public_B_apis`, `public_C_app_paths`, `public_D_others`.
//! No hard-coded domains.

use crate::config::Timeouts;
use futures::stream::{self, StreamExt};
use reports_common::caddy::{self, CaddyTarget};
use serde::Serialize;
use std::time::{Duration, Instant};

#[derive(Debug, Serialize, Clone)]
pub struct PublicResult {
    pub domain: String,
    pub path: Option<String>,
    pub url: String,
    pub upstream: String,
    pub category: String,
    pub status: Option<u16>,
    pub latency_ms: u64,
    pub ok: bool,
    pub error: Option<String>,
}

/// Load public targets from build-caddy.json. Declarative — no hard-coded URLs.
pub fn load_public_targets() -> Vec<CaddyTarget> {
    caddy::load_public_targets()
}

pub async fn run(
    targets: Vec<CaddyTarget>,
    bearer: Option<&str>,
    parallel: usize,
    timeouts: &Timeouts,
    fallback_markers: &[String],
) -> Vec<PublicResult> {
    let client = match build_client(timeouts) {
        Ok(c) => c,
        Err(e) => {
            return targets
                .into_iter()
                .map(|t| PublicResult {
                    domain: t.host.clone(),
                    path: t.path.clone(),
                    url: t.url.clone(),
                    upstream: t.upstream.clone(),
                    category: t.category.clone(),
                    status: None,
                    latency_ms: 0,
                    ok: false,
                    error: Some(format!("client build failed: {}", e)),
                })
                .collect();
        }
    };
    let bearer = bearer.map(|s| s.to_string());
    let markers: Vec<String> = fallback_markers.to_vec();

    stream::iter(targets)
        .map(|t| {
            let client = client.clone();
            let bearer = bearer.clone();
            let markers = markers.clone();
            async move { probe_one(&client, t, bearer.as_deref(), &markers).await }
        })
        .buffer_unordered(parallel)
        .collect::<Vec<_>>()
        .await
}

/// True when `upstream` is itself the GitHub-Pages backend — for those targets
/// a GitHub-Pages page legitimately *is* the real response, so the GH-Pages
/// fallback marker must NOT count as a failure (avoid false reds).
fn upstream_is_github_pages(upstream: &str) -> bool {
    upstream.contains("github.io")
}

/// Detect an edge fallback masquerading as a healthy response (false-green).
///
/// Two distinct edge fallbacks exist:
///   1. Caddy wormhole — HTTP 200 with "Wrong Wormhole". This is ALWAYS a miss
///      (no route matched), valid for any target regardless of path.
///   2. GitHub-Pages 404 fallthrough — when a *host-root* route's upstream is
///      down, Caddy falls through to the GitHub-Pages backend. This only means
///      "down" for host-root targets (`path == None`) whose upstream is NOT
///      itself GitHub Pages. For *sub-path* routes (e.g. `/crawlee`,
///      `/c3-services-api`) the bare base path 404s to GitHub Pages BY DESIGN
///      even when the upstream is healthy (proven: c3-services-api is up yet
///      `/c3-services-api` → GH-Pages 404). So the GH-Pages marker MUST be
///      ignored for sub-path targets — health of path routes is established by
///      the private `*.app` WG-direct probe, not the bare-path edge probe.
///
/// Returns the offending marker if the body is a genuine down-signal.
fn detect_fallback<'a>(
    body: &str,
    upstream: &str,
    path: Option<&str>,
    markers: &'a [String],
) -> Option<&'a str> {
    let is_gh_upstream = upstream_is_github_pages(upstream);
    let is_host_root = path.map(|p| p.is_empty() || p == "/").unwrap_or(true);
    for m in markers {
        if !body.contains(m.as_str()) {
            continue;
        }
        if m.contains("GitHub Pages") {
            // GH-Pages fallthrough only signals "down" for host-root targets
            // backed by a non-GH-Pages upstream.
            if !is_host_root || is_gh_upstream {
                continue;
            }
        }
        return Some(m.as_str());
    }
    None
}

fn build_client(t: &Timeouts) -> anyhow::Result<reqwest::Client> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(t.http_connect_secs))
        .timeout(Duration::from_secs(t.http_total_secs))
        .danger_accept_invalid_certs(false)
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()?;
    Ok(client)
}

async fn probe_one(
    client: &reqwest::Client,
    target: CaddyTarget,
    bearer: Option<&str>,
    fallback_markers: &[String],
) -> PublicResult {
    let mut req = client.get(&target.url);
    if let Some(b) = bearer {
        req = req.bearer_auth(b);
    }
    let t = Instant::now();
    match req.send().await {
        Ok(r) => {
            let status_code = r.status();
            let status = status_code.as_u16();
            // Liveness — the server responded (we only sent a bare GET):
            //   2xx/3xx ok, 401/403 auth-gated, 404 no-root, 405 wrong-method,
            //   400 malformed-for-this-protocol (WS-only endpoints like the
            //   wireguard ws-tunnel reject a plain GET with 400). Mirrors the
            //   private-probe liveness set in reports-common/probe.rs.
            let status_ok = status_code.is_success()
                || status_code.is_redirection()
                || matches!(status, 400 | 401 | 403 | 404 | 405);
            // Read the body to defeat the edge false-green trap: the Caddy
            // wormhole serves HTTP 200 on missing routes, and a path route
            // whose upstream is down falls through to the GitHub-Pages backend
            // (404). Status alone is a lie — inspect the body.
            let body = r.text().await.unwrap_or_default();
            let fallback =
                detect_fallback(&body, &target.upstream, target.path.as_deref(), fallback_markers);
            let (ok, error) = match fallback {
                Some(marker) => (
                    false,
                    Some(format!(
                        "edge fallback (upstream down): body matched \"{}\"",
                        marker
                    )),
                ),
                None => (status_ok, None),
            };
            PublicResult {
                domain: target.host,
                path: target.path,
                url: target.url,
                upstream: target.upstream,
                category: target.category,
                status: Some(status),
                latency_ms: t.elapsed().as_millis() as u64,
                ok,
                error,
            }
        }
        Err(e) => PublicResult {
            domain: target.host,
            path: target.path,
            url: target.url,
            upstream: target.upstream,
            category: target.category,
            status: None,
            latency_ms: t.elapsed().as_millis() as u64,
            ok: false,
            error: Some(e.to_string()),
        },
    }
}
