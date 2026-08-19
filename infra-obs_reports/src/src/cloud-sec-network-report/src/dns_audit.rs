use crate::context::NetworkContext;
use crate::types::DnsValidationResult;
use futures::stream::{self, StreamExt};
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::checks;
use reports_common::types::{Check, Severity};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

/// Concurrency cap for DNS probes — public resolvers handle parallel
/// queries fine, and the home-lab domain count keeps total work small.
const DNS_AUDIT_PARALLEL: usize = 8;

/// Dual-path DNS validation: public resolvers (always) + Hickory internal (when WG up)
pub async fn validate_dns(
    ctx: &NetworkContext,
    caps: &RuntimeCapabilities,
) -> (Vec<Check>, Vec<DnsValidationResult>) {
    let mut all_checks = Vec::new();
    let mut all_results = Vec::new();

    let public = checks::public_resolver();
    let google = checks::google_resolver();

    // Deduplicate domains
    let mut seen = HashSet::new();
    let domains: Vec<String> = ctx
        .caddy_routes
        .iter()
        .filter(|r| !r.domain.is_empty())
        .filter(|r| seen.insert(r.domain.clone()))
        .map(|r| r.domain.clone())
        .collect();

    println!(
        "DNS audit: {} domains (public{}) ",
        domains.len(),
        if caps.hickory_up { " + Hickory internal" } else { "" }
    );

    // ── Wildcard probe — for each parent domain, resolve a random subdomain.
    //    If the wildcard is active, individual NXDOMAIN for known subdomains is
    //    EXPECTED (DNS only has *.<parent>, not per-host A). Downgrade those
    //    to Info instead of Critical.
    // Wildcard probe — parallel per-parent.
    let parents: HashSet<String> = domains.iter().map(|d| parent_domain(d)).collect();
    let parent_vec: Vec<String> = parents.into_iter().collect();
    let probe_results: Vec<(String, bool)> = stream::iter(parent_vec.into_iter())
        .map(|parent| {
            let public = public.clone();
            async move {
                let probe = format!(
                    "nxprobe-{}.{}",
                    chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0),
                    parent
                );
                let cf_probe = checks::dns_resolve_retry(&public, &probe, 3, 500).await;
                (parent, cf_probe.is_some())
            }
        })
        .buffer_unordered(DNS_AUDIT_PARALLEL)
        .collect()
        .await;
    let mut wildcard_active: HashSet<String> = HashSet::new();
    for (parent, active) in probe_results {
        if active {
            println!("  wildcard A active for *.{}", parent);
            wildcard_active.insert(parent);
        }
    }

    // ── External: public resolvers (Cloudflare + Google cross-check) ──
    let ext_outputs: Vec<(DnsValidationResult, Check)> =
        stream::iter(domains.iter().cloned())
            .map(|domain| {
                let public = public.clone();
                let google = google.clone();
                let wildcard_active = wildcard_active.clone();
                async move {
                    let t = Instant::now();
                    let cf_result = checks::dns_resolve_retry(&public, &domain, 2, 300).await;
                    let google_result = checks::dns_resolve_retry(&google, &domain, 2, 300).await;
                    let elapsed = t.elapsed().as_millis() as u64;

                    let cf_ip = cf_result.unwrap_or_else(|| "NXDOMAIN".into());
                    let google_ip = google_result.unwrap_or_else(|| "NXDOMAIN".into());
                    let matches = cf_ip == google_ip && cf_ip != "NXDOMAIN";
                    let parent = parent_domain(&domain);
                    let covered_by_wildcard = wildcard_active.contains(&parent);

                    let result = DnsValidationResult {
                        domain: domain.clone(),
                        record_type: "A".into(),
                        resolver: "external".into(),
                        expected: cf_ip.clone(),
                        actual: google_ip.clone(),
                        matches,
                    };

                    let passed = cf_ip != "NXDOMAIN" || covered_by_wildcard;
                    let severity = if cf_ip == "NXDOMAIN" && !covered_by_wildcard {
                        Severity::Critical
                    } else if cf_ip != "NXDOMAIN" && !matches {
                        Severity::Warning
                    } else {
                        Severity::Info
                    };

                    let details = if matches {
                        format!("A={}", cf_ip)
                    } else if cf_ip == "NXDOMAIN" {
                        if covered_by_wildcard {
                            format!("no individual A — covered by *.{} wildcard", parent)
                        } else {
                            "NXDOMAIN (no A record)".into()
                        }
                    } else {
                        format!("CF={} Google={} (mismatch)", cf_ip, google_ip)
                    };

                    let check = Check {
                        name: format!("ext:dns:A:{}", domain),
                        passed,
                        details,
                        duration_ms: elapsed,
                        error: None,
                        severity,
                    };
                    (result, check)
                }
            })
            .buffer_unordered(DNS_AUDIT_PARALLEL)
            .collect()
            .await;
    // Build the public-IP map FIRST (Hickory loop needs it) before pushing
    // results into the shared vec.
    let public_a_by_domain: HashMap<String, String> = ext_outputs
        .iter()
        .map(|(r, _)| (r.domain.clone(), r.expected.clone()))
        .collect();
    for (r, c) in ext_outputs {
        all_results.push(r);
        all_checks.push(c);
    }

    // ── Internal: Hickory DNS at 10.0.0.1 (when WG is up) ──
    if caps.hickory_up {
        let hickory = checks::hickory_resolver();
        let int_outputs: Vec<(DnsValidationResult, Check)> =
            stream::iter(domains.iter().cloned())
                .map(|domain| {
                    let hickory = hickory.clone();
                    let public_ip = public_a_by_domain
                        .get(&domain)
                        .cloned()
                        .unwrap_or_else(|| "unknown".into());
                    async move {
                        let t = Instant::now();
                        let hickory_result = checks::dns_resolve(&hickory, &domain).await;
                        let elapsed = t.elapsed().as_millis() as u64;
                        let hickory_ip = hickory_result.unwrap_or_else(|| "NXDOMAIN".into());
                        let matches = hickory_ip != "NXDOMAIN";

                        let result = DnsValidationResult {
                            domain: domain.clone(),
                            record_type: "A".into(),
                            resolver: "hickory".into(),
                            expected: public_ip.clone(),
                            actual: hickory_ip.clone(),
                            matches,
                        };

                        let passed = hickory_ip != "NXDOMAIN";
                        let details = if passed {
                            format!("Hickory A={} (public={})", hickory_ip, public_ip)
                        } else {
                            format!("Hickory NXDOMAIN (public={})", public_ip)
                        };

                        let check = Check {
                            name: format!("int:dns:A:{}", domain),
                            passed,
                            details,
                            duration_ms: elapsed,
                            error: None,
                            severity: if passed { Severity::Info } else { Severity::Warning },
                        };
                        (result, check)
                    }
                })
                .buffer_unordered(DNS_AUDIT_PARALLEL)
                .collect()
                .await;
        for (r, c) in int_outputs {
            all_results.push(r);
            all_checks.push(c);
        }
    }

    // ── Mail DNS: MX/SPF/DMARC (external only — authoritative check) ──
    // MX/SPF/DMARC are ZONE-APEX records published on the mail-RECEIVING
    // domain (the apex that owns the MX). Subdomains that merely contain the
    // substring "mail" — e.g. `webmail.diegonmarcos.com` (Cypht/SnappyMail UI)
    // or `mail.diegonmarcos.com` (Maddy admin UI) — are plain HTTPS hosts
    // behind the edge; they neither receive mail nor publish their own
    // MX/SPF/DMARC, so demanding those records on them is a false-positive.
    // Audit the apex (the real MX zone) only.
    let base_domain = "diegonmarcos.com";
    let mut mail_domains: Vec<String> = Vec::new();
    // Include any explicitly-declared apex-level mail zone (defensive: if a
    // route ever surfaces the bare apex it is the MX owner). Everything else
    // (UI subdomains) is intentionally excluded.
    for d in &domains {
        let labels = d.split('.').count();
        if labels <= 2 && d.contains("mail") {
            mail_domains.push(d.clone());
        }
    }
    if !mail_domains.contains(&base_domain.to_string()) {
        mail_domains.push(base_domain.to_string());
    }

    let mail_outputs: Vec<Vec<(DnsValidationResult, Check)>> =
        stream::iter(mail_domains.into_iter())
            .map(|domain| {
                let public = public.clone();
                async move {
                    let mut out = Vec::with_capacity(3);

                    // MX
                    let t = Instant::now();
                    let mx_records = checks::dns_mx(&public, &domain).await;
                    let elapsed = t.elapsed().as_millis() as u64;
                    let mx_str = if mx_records.is_empty() {
                        "none".into()
                    } else {
                        mx_records
                            .iter()
                            .map(|(p, e)| format!("{} {}", p, e))
                            .collect::<Vec<_>>()
                            .join(", ")
                    };
                    let mx_passed = !mx_records.is_empty();
                    out.push((
                        DnsValidationResult {
                            domain: domain.clone(),
                            record_type: "MX".into(),
                            resolver: "external".into(),
                            expected: "(any)".into(),
                            actual: mx_str.clone(),
                            matches: mx_passed,
                        },
                        Check {
                            name: format!("ext:dns:MX:{}", domain),
                            passed: mx_passed,
                            details: if mx_passed {
                                format!("MX={}", mx_str)
                            } else {
                                "No MX records found".into()
                            },
                            duration_ms: elapsed,
                            error: None,
                            severity: if mx_passed { Severity::Info } else { Severity::Warning },
                        },
                    ));

                    // SPF
                    let t = Instant::now();
                    let txt = checks::dns_txt(&public, &domain).await;
                    let elapsed = t.elapsed().as_millis() as u64;
                    let has_spf = txt.as_ref().map(|t| t.contains("v=spf1")).unwrap_or(false);
                    out.push((
                        DnsValidationResult {
                            domain: domain.clone(),
                            record_type: "SPF".into(),
                            resolver: "external".into(),
                            expected: "v=spf1 ...".into(),
                            actual: if has_spf {
                                txt.unwrap_or_default()
                            } else {
                                "missing".into()
                            },
                            matches: has_spf,
                        },
                        Check {
                            name: format!("ext:dns:SPF:{}", domain),
                            passed: has_spf,
                            details: if has_spf {
                                "SPF record present".into()
                            } else {
                                "No SPF record".into()
                            },
                            duration_ms: elapsed,
                            error: None,
                            severity: if has_spf { Severity::Info } else { Severity::Warning },
                        },
                    ));

                    // DMARC
                    let dmarc_domain = format!("_dmarc.{}", domain);
                    let t = Instant::now();
                    let dmarc_txt = checks::dns_txt(&public, &dmarc_domain).await;
                    let elapsed = t.elapsed().as_millis() as u64;
                    let has_dmarc =
                        dmarc_txt.as_ref().map(|t| t.contains("v=DMARC1")).unwrap_or(false);
                    out.push((
                        DnsValidationResult {
                            domain: domain.clone(),
                            record_type: "DMARC".into(),
                            resolver: "external".into(),
                            expected: "v=DMARC1 ...".into(),
                            actual: dmarc_txt.unwrap_or_else(|| "missing".into()),
                            matches: has_dmarc,
                        },
                        Check {
                            name: format!("ext:dns:DMARC:{}", domain),
                            passed: has_dmarc,
                            details: if has_dmarc {
                                "DMARC record present".into()
                            } else {
                                "No DMARC record".into()
                            },
                            duration_ms: elapsed,
                            error: None,
                            severity: if has_dmarc {
                                Severity::Info
                            } else {
                                Severity::Warning
                            },
                        },
                    ));

                    out
                }
            })
            .buffer_unordered(DNS_AUDIT_PARALLEL)
            .collect()
            .await;
    for batch in mail_outputs {
        for (r, c) in batch {
            all_results.push(r);
            all_checks.push(c);
        }
    }

    // ── DNS hygiene: the public wildcard must not publish private/mesh IPs ──
    // The WG fast-path resolves *.diegonmarcos.com -> 10.0.0.1 for on-mesh
    // clients via Hickory (split-horizon). If that 10.0.0.1 A record also
    // appears in the PUBLIC wildcard it (a) discloses internal topology and
    // (b) blackholes ~50% of external clients (they pick the unroutable mesh
    // IP and time out). Probe a random label per parent so we read the
    // wildcard itself (not a per-host override) and flag any RFC1918 answer.
    let hygiene_parents: HashSet<String> = domains.iter().map(|d| parent_domain(d)).collect();
    let hygiene: Vec<Check> = stream::iter(hygiene_parents.into_iter())
        .map(|parent| {
            let public = public.clone();
            async move {
                let t = Instant::now();
                // A single A query can return a truncated / reordered subset of
                // a multi-value wildcard (or transiently time out). To reliably
                // observe the FULL published A set — and not miss a mesh IP that
                // only shows up in some answers — probe several distinct random
                // labels and UNION every returned IP.
                let mut seen_ips: Vec<String> = Vec::new();
                for n in 0..4u32 {
                    let probe = format!(
                        "hygiene-{}-{}.{}",
                        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0),
                        n,
                        parent
                    );
                    for ip in checks::dns_resolve_all(&public, &probe).await {
                        if !seen_ips.contains(&ip) {
                            seen_ips.push(ip);
                        }
                    }
                }
                let ips = seen_ips;
                let elapsed = t.elapsed().as_millis() as u64;
                let private: Vec<String> = ips
                    .iter()
                    .filter(|ip| {
                        ip.parse::<std::net::Ipv4Addr>()
                            .map(|a| a.is_private())
                            .unwrap_or(false)
                    })
                    .cloned()
                    .collect();
                let leaked = !private.is_empty();
                Check {
                    name: format!("ext:dns:wildcard-hygiene:*.{}", parent),
                    passed: !leaked,
                    details: if leaked {
                        format!(
                            "public wildcard *.{} LEAKS private/mesh IP [{}] — full A set [{}]",
                            parent,
                            private.join(", "),
                            ips.join(", ")
                        )
                    } else if ips.is_empty() {
                        format!("*.{}: no wildcard A (skip)", parent)
                    } else {
                        format!("*.{} public A clean [{}]", parent, ips.join(", "))
                    },
                    duration_ms: elapsed,
                    error: None,
                    severity: if leaked { Severity::Warning } else { Severity::Info },
                }
            }
        })
        .buffer_unordered(DNS_AUDIT_PARALLEL)
        .collect()
        .await;
    all_checks.extend(hygiene);

    (all_checks, all_results)
}

/// Return the parent domain (last 2 labels) for wildcard probing.
/// e.g. "auth.diegonmarcos.com" -> "diegonmarcos.com",
///      "diegonmarcos.com"      -> "diegonmarcos.com".
fn parent_domain(d: &str) -> String {
    let labels: Vec<&str> = d.split('.').collect();
    if labels.len() <= 2 {
        d.to_string()
    } else {
        labels[labels.len() - 2..].join(".")
    }
}
