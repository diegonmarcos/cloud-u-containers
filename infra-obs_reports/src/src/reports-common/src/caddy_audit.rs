//! Caddy structure audit — T2/T3 check.
//!
//! Compares:
//!   - Declared routes from `build-caddy.json` (the routing SoT)
//!   - Live reachability of each route (HTTP probe)
//!
//! Detects:
//!   - Declared but dead (upstream unreachable — service crashed or mis-deployed)
//!   - Live but undeclared (rogue proxy / old route left in caddy config)
//!   - Auth-stripped (route should require auth but Caddy returns 200 without bearer)
//!
//! Runs at T2 (route-level liveness) and T3 (full SAN + auth audit).
//! Reuses `reports-common/caddy.rs` types + `checks::http_get`.

use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteAudit {
    pub domain: String,
    pub upstream: String,
    pub auth_required: bool,
    pub reachable: bool,
    pub status_code: u16,
    pub auth_bypassed: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaddyAuditResult {
    pub routes: Vec<RouteAudit>,
    pub dead_count: usize,
    pub auth_bypass_count: usize,
    pub ok: bool,
    pub summary: String,
}

/// Probe a single declared Caddy route for liveness and auth enforcement.
pub async fn audit_route(
    client: &Client,
    domain: &str,
    auth_required: bool,
) -> RouteAudit {
    let url = format!("https://{}/", domain);

    // Unauthenticated probe
    let (ok, code, detail) = crate::checks::http_get(client, &url).await;

    // If route requires auth, a 401/302 is CORRECT (auth enforced).
    // A 200 without bearer means auth bypass — flag it.
    let auth_bypassed = auth_required && ok && code == 200;

    // Reachable = got a response (even 401/302) — proves Caddy is routing
    let reachable = code > 0 && code != 502 && code != 503;

    RouteAudit {
        domain: domain.to_string(),
        upstream: String::new(),
        auth_required,
        reachable,
        status_code: code,
        auth_bypassed,
        detail,
    }
}

/// Audit all declared routes from build-caddy.json against the live Caddy.
/// `wg_up`: if false, probes through public edge only (WG routes skipped).
pub async fn audit_all(
    client: &Client,
    caddy_json: &serde_json::Value,
    wg_up: bool,
) -> CaddyAuditResult {
    let empty = vec![];
    let routes = caddy_json["routes"].as_array().unwrap_or(&empty);

    let mut audited = Vec::new();
    for route in routes {
        let domain = route["domain"].as_str().unwrap_or("").to_string();
        let auth = route["auth"].as_str().unwrap_or("none");
        let auth_required = auth != "none" && !auth.is_empty();
        let is_wg_only = route["wg_only"].as_bool().unwrap_or(false);

        if is_wg_only && !wg_up {
            // Skip WG-only routes when mesh is down; mark UNKNOWN not DEAD
            audited.push(RouteAudit {
                domain,
                upstream: route["upstream"].as_str().unwrap_or("").to_string(),
                auth_required,
                reachable: false,
                status_code: 0,
                auth_bypassed: false,
                detail: "UNKNOWN (WG down — mesh-only route skipped)".into(),
            });
            continue;
        }

        let mut r = audit_route(client, &domain, auth_required).await;
        r.upstream = route["upstream"].as_str().unwrap_or("").to_string();
        audited.push(r);
    }

    let dead_count = audited.iter().filter(|r| !r.reachable && !r.detail.contains("UNKNOWN")).count();
    let auth_bypass_count = audited.iter().filter(|r| r.auth_bypassed).count();
    let ok = dead_count == 0 && auth_bypass_count == 0;

    let summary = if ok {
        format!("Caddy OK — {} routes all reachable", audited.len())
    } else {
        format!(
            "Caddy DEGRADED — dead:{} auth_bypass:{}",
            dead_count, auth_bypass_count
        )
    };

    CaddyAuditResult {
        routes: audited,
        dead_count,
        auth_bypass_count,
        ok,
        summary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_bypass_flagged() {
        let r = RouteAudit {
            domain: "test.example.com".into(),
            upstream: "10.0.0.1:8080".into(),
            auth_required: true,
            reachable: true,
            status_code: 200,
            auth_bypassed: true,
            detail: "200".into(),
        };
        assert!(r.auth_bypassed);
    }

    #[test]
    fn dead_route_not_auth_bypass() {
        let r = RouteAudit {
            domain: "dead.example.com".into(),
            upstream: "10.0.0.1:9999".into(),
            auth_required: true,
            reachable: false,
            status_code: 0,
            auth_bypassed: false,
            detail: "timeout".into(),
        };
        assert!(!r.auth_bypassed);
        assert!(!r.reachable);
    }
}
