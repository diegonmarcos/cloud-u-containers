//! Data-driven Caddy target loader — shared across all report crates.
//!
//! SOURCE OF TRUTH: `build-caddy.json` (output of `build-caddy-routes.ts` derive).
//! Never hard-code URLs/hosts/upstreams here.
//!
//! Exposes:
//!   - `load_public_targets()`  — every public URL Caddy serves (edge: *.diegonmarcos.com).
//!   - `load_private_app_targets()` — `*.app` canonical private URLs (Hickory + Caddy wildcard).
//!   - `load_private_db_targets()` — `*.db` catalog entries.
//!   - `load_private_all_targets()` — app + db (merged).
//!
//! Schema inside build-caddy.json (array elements in categorised keys):
//!   { host, path?, upstream, kind, tls, zone, service?, notes? }
//! except `.routes[]` which is the legacy simplified aggregate:
//!   { domain, upstream, comment, auth? }

use crate::context::find_cloud_data_file;
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
pub struct CaddyTarget {
    /// Hostname (e.g. `ide.diegonmarcos.com`, `code-server-https-8443.app`).
    pub host: String,
    /// Optional path (e.g. `/crawlee`).
    pub path: Option<String>,
    /// Backend upstream `ip:port` (may be `embedded` for sqlite DB catalog).
    pub upstream: String,
    /// `reverse_proxy` | `catalog` | `redirect` | `canonical` | ...
    pub kind: String,
    /// `public` | `on_demand` | `internal` | `none`.
    pub tls: String,
    /// `com` (public zone) | `app` | `db`.
    pub zone: String,
    /// Service name declared in the source build.json (may be null for shared routes).
    pub service: Option<String>,
    /// Which build-caddy.json key this target came from.
    pub category: String,
    /// Optional auth hint (from legacy `.routes[].auth`).
    pub auth: Option<String>,
    /// Composed full URL (`https://host[/path]`). Used by public probes.
    pub url: String,
}

/// Categories in build-caddy.json that hold public endpoints.
const PUBLIC_CATEGORIES: &[&str] = &[
    "public_A_mcp",
    "public_B_apis",
    "public_C_app_paths",
    "public_D_others",
];

/// Categories in build-caddy.json that hold private `.app` canonical hosts.
const PRIVATE_APP_CATEGORIES: &[&str] = &[
    "private_A0_app_short",
    "private_A1_app_canonical",
    "private_A2_app_portless",
];

/// Load raw `build-caddy.json` value.
pub fn load_build_caddy() -> Option<Value> {
    find_cloud_data_file("build-caddy.json")
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
}

/// One Caddy L4 (layer-4 SNI/TCP mux) route from build-caddy.json:.l4_routes.
/// This is the SoT for mail-client ports (IMAPS/SMTPS demuxed on :443 by SNI,
/// plus the plain :25 MX listener). R4 renders MAIL_PORTS from these instead
/// of a hardcoded list.
#[derive(Debug, Clone, Serialize)]
pub struct L4Port {
    /// Public listener port (443 for SNI-muxed mail, 25 for MX).
    pub port: u16,
    /// Backend `ip:port` the route forwards to.
    pub upstream: String,
    /// SNI hostname that selects this route (None for the non-SNI :25 MX).
    pub sni: Option<String>,
    pub comment: String,
}

/// Parse the L4 route map from a loaded build-caddy value.
/// Pure (no I/O) so it unit-tests without a filesystem.
pub fn parse_l4_ports(json: &Value) -> Vec<L4Port> {
    json["l4_routes"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|r| {
                    let port = r["port"].as_u64()? as u16;
                    Some(L4Port {
                        port,
                        upstream: r["upstream"].as_str().unwrap_or("?").to_string(),
                        sni: r["sni"].as_str().map(|s| s.to_string()),
                        comment: r["comment"].as_str().unwrap_or("").to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Load the Caddy L4 route map (mail ports live here). Data-driven from
/// build-caddy.json — empty vec if the file is absent.
pub fn load_l4_ports() -> Vec<L4Port> {
    load_build_caddy().map(|j| parse_l4_ports(&j)).unwrap_or_default()
}

/// L4 routes that carry mail (SMTPS/IMAPS via SNI, or the :25 MX). Identified
/// by the SNI hostname / upstream port shape — the mail listeners are the only
/// L4 routes whose SNI starts with imap/smtp or whose port is the plain MX 25.
pub fn load_l4_mail_ports() -> Vec<L4Port> {
    load_l4_ports()
        .into_iter()
        .filter(|r| is_mail_l4(r))
        .collect()
}

fn is_mail_l4(r: &L4Port) -> bool {
    if r.port == 25 {
        return true;
    }
    match &r.sni {
        Some(sni) => {
            let s = sni.to_ascii_lowercase();
            s.starts_with("imap") || s.starts_with("smtp") || s.starts_with("mail") || s.starts_with("jmap")
        }
        None => false,
    }
}

fn compose_url(host: &str, path: Option<&str>, tls: &str) -> String {
    let scheme = if tls == "none" { "http" } else { "https" };
    match path {
        Some(p) if !p.is_empty() && p != "null" => format!("{}://{}{}", scheme, host, p),
        _ => format!("{}://{}/", scheme, host),
    }
}

/// Caddy site addresses may name several hosts in one block, e.g.
/// `"diegonmarcos.com, www.diegonmarcos.com"`. A comma inside a URL is
/// invalid (reqwest rejects it as a "builder error" before any request
/// is sent), so split into individual hostnames — each gets its own
/// probe target. The comma form stays untouched in build-caddy.json
/// because the Caddyfile generator needs it verbatim.
fn split_hosts(host: &str) -> impl Iterator<Item = &str> {
    host.split(',').map(str::trim).filter(|h| !h.is_empty())
}

fn parse_entry(v: &Value, category: &str) -> Vec<CaddyTarget> {
    let Some(host_raw) = v["host"].as_str() else {
        return Vec::new();
    };
    if host_raw.is_empty() || host_raw.starts_with('<') {
        return Vec::new(); // `<global>`, `<catch-all>` etc.
    }
    let path = v["path"].as_str().map(|s| s.to_string());
    let upstream = v["upstream"].as_str().unwrap_or("").to_string();
    let kind = v["kind"].as_str().unwrap_or("reverse_proxy").to_string();
    let tls = v["tls"].as_str().unwrap_or("public").to_string();
    let zone = v["zone"].as_str().unwrap_or("com").to_string();
    let service = v["service"].as_str().map(|s| s.to_string());
    split_hosts(host_raw)
        .map(|host| {
            let url = compose_url(host, path.as_deref(), &tls);
            CaddyTarget {
                host: host.to_string(),
                path: path.clone(),
                upstream: upstream.clone(),
                kind: kind.clone(),
                tls: tls.clone(),
                zone: zone.clone(),
                service: service.clone(),
                category: category.to_string(),
                auth: None,
                url,
            }
        })
        .collect()
}

fn parse_legacy_route(v: &Value) -> Vec<CaddyTarget> {
    let Some(domain_raw) = v["domain"].as_str() else {
        return Vec::new();
    };
    if domain_raw.is_empty() || !domain_raw.contains('.') {
        return Vec::new();
    }
    let upstream = v["upstream"].as_str().unwrap_or("").to_string();
    let auth = v["auth"].as_str().map(|s| s.to_string());
    split_hosts(domain_raw)
        .map(|domain| CaddyTarget {
            host: domain.to_string(),
            path: None,
            upstream: upstream.clone(),
            kind: "reverse_proxy".to_string(),
            tls: "public".to_string(),
            zone: "com".to_string(),
            service: None,
            category: "routes".to_string(),
            auth: auth.clone(),
            url: format!("https://{}/", domain),
        })
        .collect()
}

/// Load all public endpoints (edge-served domains). Deduplicated by (host, path).
pub fn load_public_targets() -> Vec<CaddyTarget> {
    let Some(json) = load_build_caddy() else {
        return Vec::new();
    };

    let mut out: Vec<CaddyTarget> = Vec::new();

    // Legacy simplified `.routes[]` (domain + upstream).
    if let Some(arr) = json["routes"].as_array() {
        out.extend(arr.iter().flat_map(parse_legacy_route));
    }

    // Categorised entries.
    for cat in PUBLIC_CATEGORIES {
        if let Some(arr) = json[cat].as_array() {
            out.extend(arr.iter().flat_map(|v| parse_entry(v, cat)));
        }
    }

    dedup_targets(&mut out);
    out
}

/// Load private `.app` canonical targets (`private_A1_app_canonical` etc.).
pub fn load_private_app_targets() -> Vec<CaddyTarget> {
    let Some(json) = load_build_caddy() else {
        return Vec::new();
    };
    let mut out: Vec<CaddyTarget> = Vec::new();
    for cat in PRIVATE_APP_CATEGORIES {
        if let Some(arr) = json[cat].as_array() {
            out.extend(arr.iter().flat_map(|v| parse_entry(v, cat)));
        }
    }
    dedup_targets(&mut out);
    out
}

/// Load `.db` catalog targets.
pub fn load_private_db_targets() -> Vec<CaddyTarget> {
    let Some(json) = load_build_caddy() else {
        return Vec::new();
    };
    let mut out: Vec<CaddyTarget> = json["private_B0_db"]
        .as_array()
        .map(|a| a.iter().flat_map(|v| parse_entry(v, "private_B0_db")).collect())
        .unwrap_or_default();
    dedup_targets(&mut out);
    out
}

/// Load all private targets (app + db). Deduplicated by (host, path).
pub fn load_private_all_targets() -> Vec<CaddyTarget> {
    let mut out = load_private_app_targets();
    out.extend(load_private_db_targets());
    dedup_targets(&mut out);
    out
}

fn dedup_targets(out: &mut Vec<CaddyTarget>) {
    out.sort_by(|a, b| {
        a.host
            .cmp(&b.host)
            .then(a.path.cmp(&b.path))
            .then(a.upstream.cmp(&b.upstream))
    });
    out.dedup_by(|a, b| a.host == b.host && a.path == b.path);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fire Rule #4: a task is not done until it has a tester.
    ///
    /// Asserts that build-caddy.json is wired in and yields the expected
    /// minimum target counts. These are lower bounds that hold as long as
    /// the core services exist.
    #[test]
    fn loaders_return_non_trivial_sets() {
        // Gate on file presence so the test doesn't fail in sandbox builds
        // that lack cloud-data access.
        if load_build_caddy().is_none() {
            eprintln!("build-caddy.json not found — skipping");
            return;
        }

        let pubs = load_public_targets();
        let apps = load_private_app_targets();
        let dbs = load_private_db_targets();

        assert!(pubs.len() >= 10, "expected ≥10 public targets, got {}", pubs.len());
        assert!(apps.len() >= 50, "expected ≥50 private .app targets, got {}", apps.len());
        assert!(dbs.len() >= 20, "expected ≥20 private .db targets, got {}", dbs.len());

        // Every target has a non-empty URL.
        for t in pubs.iter().chain(apps.iter()).chain(dbs.iter()) {
            assert!(!t.host.is_empty());
            assert!(!t.url.is_empty());
        }

        // At least one .app host uses the .app zone suffix.
        assert!(apps.iter().any(|t| t.host.ends_with(".app")),
                "expected ≥1 .app host in private_app targets");

        // At least one .db host uses the .db zone suffix.
        assert!(dbs.iter().any(|t| t.host.ends_with(".db")),
                "expected ≥1 .db host in private_db targets");
    }

    #[test]
    fn compose_url_joins_host_and_path() {
        assert_eq!(
            compose_url("ide.diegonmarcos.com", None, "public"),
            "https://ide.diegonmarcos.com/"
        );
        assert_eq!(
            compose_url("api.diegonmarcos.com", Some("/crawlee"), "public"),
            "https://api.diegonmarcos.com/crawlee"
        );
        assert_eq!(
            compose_url("x.app", None, "on_demand"),
            "https://x.app/"
        );
        assert_eq!(
            compose_url("x.local", None, "none"),
            "http://x.local/"
        );
    }

    /// R4: MAIL_PORTS is data-driven from build-caddy.json:.l4_routes.
    #[test]
    fn parse_l4_ports_extracts_mail_listeners() {
        let json = serde_json::json!({
            "l4_routes": [
                { "port": 25, "upstream": "10.0.0.3:25", "comment": "SMTP MX" },
                { "port": 443, "upstream": "10.0.0.3:2993", "comment": "IMAPS", "sni": "imap.diegonmarcos.com" },
                { "port": 443, "upstream": "10.0.0.3:2465", "comment": "SMTPS", "sni": "smtps.diegonmarcos.com" },
                { "port": 443, "upstream": "10.0.0.6:8443", "comment": "some app", "sni": "ide.diegonmarcos.com" }
            ]
        });
        let all = parse_l4_ports(&json);
        assert_eq!(all.len(), 4);
        // Only the three mail listeners are mail (the ide app route is not).
        let mail: Vec<_> = all.iter().filter(|r| is_mail_l4(r)).collect();
        assert_eq!(mail.len(), 3, "expected 25 + imap + smtps, got {}", mail.len());
        assert!(mail.iter().any(|r| r.port == 25 && r.sni.is_none()));
        assert!(mail.iter().any(|r| r.sni.as_deref() == Some("imap.diegonmarcos.com")));
        assert!(mail.iter().any(|r| r.sni.as_deref() == Some("smtps.diegonmarcos.com")));
        // upstream carried through
        assert_eq!(
            mail.iter().find(|r| r.port == 25).unwrap().upstream,
            "10.0.0.3:25"
        );
    }

    #[test]
    fn parse_l4_ports_empty_when_absent() {
        assert!(parse_l4_ports(&serde_json::json!({})).is_empty());
    }
}
