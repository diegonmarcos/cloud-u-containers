use crate::types::*;
use std::net::SocketAddr;
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;
use trust_dns_resolver::config::{NameServerConfig, Protocol, ResolverConfig, ResolverOpts};
use trust_dns_resolver::TokioAsyncResolver;

const MAIL_WG_IP: &str = "10.0.0.3";
const PROXY_WG_IP: &str = "10.0.0.1";
const MAIL_DOMAIN: &str = "mail.diegonmarcos.com";
const STALWART_DOMAIN: &str = "mail-stalwart.diegonmarcos.com";
const BASE_DOMAIN: &str = "diegonmarcos.com";
const HICKORY_IP: &str = "10.0.0.1";

const TCP_TIMEOUT: Duration = Duration::from_secs(3);
const TLS_TIMEOUT: Duration = Duration::from_secs(5);
const DNS_TIMEOUT: Duration = Duration::from_secs(5);
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);

// ── Network-only checks (no SSH) ────────────────────────────────────

/// Run all mail network checks in parallel. Returns MailHealthData with
/// outbound_path, inbound_path, dns_auth, and tls_ports populated.
/// The containers and internals fields are left empty for fill_from_vmdata().
pub async fn collect_mail_network() -> MailHealthData {
    let (outbound_path, inbound_path, dns_auth, tls_ports, stalwart) = tokio::join!(
        check_outbound_path(),
        check_inbound_path(),
        check_dns_auth(),
        check_tls_ports(),
        check_stalwart(),
    );

    let mut health = MailHealthData {
        outbound_path,
        inbound_path,
        dns_auth,
        tls_ports,
        containers: Vec::new(),
        internals: Vec::new(),
        stalwart,
        summary: MailHealthSummary::default(),
    };

    recompute_summary(&mut health);
    health
}

/// Fill containers and internals from already-collected VM SSH data.
/// Looks for the oci-mail VM in the slice and extracts mail-specific fields.
pub fn fill_from_vmdata(health: &mut MailHealthData, vms: &[VmData]) {
    let mail_vm = vms.iter().find(|v| v.name == "oci-mail");

    if let Some(vm) = mail_vm {
        // ── Containers ──────────────────────────────────────────────
        let mail_containers = ["maddy", "http-to-smtp-proxy-api", "snappymail", "stalwart"];
        for name in &mail_containers {
            let found = vm
                .container_list
                .iter()
                .find(|c| c.name.contains(name));
            let (passed, details) = match found {
                Some(c) if c.status.to_lowercase().contains("up") => {
                    (true, format!("{}: {}", c.name, c.status))
                }
                Some(c) => (false, format!("{}: {}", c.name, c.status)),
                None => (false, format!("{} not found in container list", name)),
            };
            health.containers.push(MailCheck {
                name: format!("{} container", name),
                passed,
                details,
                severity: if passed { "info".into() } else { "critical".into() },
                duration_ms: 0,
            });
        }

        // Check for mail container restarts
        let restart_names: Vec<String> = vm
            .restarts
            .iter()
            .filter(|(name, count)| {
                *count > 1
                    && mail_containers
                        .iter()
                        .any(|mc| name.to_lowercase().contains(mc))
            })
            .map(|(name, count)| format!("{} ({}x)", name, count))
            .collect();

        let has_restarts = !restart_names.is_empty();
        health.containers.push(MailCheck {
            name: "mail container restarts".into(),
            passed: !has_restarts,
            details: if has_restarts {
                format!("restarts: {}", restart_names.join(", "))
            } else {
                "no recent restarts".into()
            },
            severity: if has_restarts {
                "warning".into()
            } else {
                "info".into()
            },
            duration_ms: 0,
        });

        // ── Internals (from SSH-collected fields) ───────────────────
        // IMAP check
        let imap_ok = !vm.imap_check.is_empty() && vm.imap_check != "N/A";
        health.internals.push(MailCheck {
            name: "IMAP check".into(),
            passed: imap_ok,
            details: if imap_ok {
                vm.imap_check.clone()
            } else {
                "IMAP check failed or not collected".into()
            },
            severity: if imap_ok { "info".into() } else { "critical".into() },
            duration_ms: 0,
        });

        // SMTP :25 banner
        let smtp_ok = !vm.smtp25_banner.is_empty() && vm.smtp25_banner != "N/A";
        health.internals.push(MailCheck {
            name: "SMTP :25 banner".into(),
            passed: smtp_ok,
            details: if smtp_ok {
                vm.smtp25_banner.clone()
            } else {
                "SMTP banner not available".into()
            },
            severity: if smtp_ok { "info".into() } else { "critical".into() },
            duration_ms: 0,
        });

        // Mail ports bound
        let ports_ok = !vm.mail_ports_bound.is_empty() && vm.mail_ports_bound != "N/A";
        health.internals.push(MailCheck {
            name: "mail ports bound".into(),
            passed: ports_ok,
            details: if ports_ok {
                vm.mail_ports_bound.clone()
            } else {
                "mail port info not available".into()
            },
            severity: if ports_ok { "info".into() } else { "warning".into() },
            duration_ms: 0,
        });

        // Maddy accounts
        let accounts_ok = vm.maddy_accounts > 0;
        health.internals.push(MailCheck {
            name: "Maddy accounts".into(),
            passed: accounts_ok,
            details: format!("{} accounts", vm.maddy_accounts),
            severity: if accounts_ok {
                "info".into()
            } else {
                "warning".into()
            },
            duration_ms: 0,
        });

        // Maddy domains
        let domains_ok = !vm.maddy_domains.is_empty() && vm.maddy_domains != "N/A";
        health.internals.push(MailCheck {
            name: "Maddy domains".into(),
            passed: domains_ok,
            details: if domains_ok {
                vm.maddy_domains.clone()
            } else {
                "no domains configured".into()
            },
            severity: if domains_ok {
                "info".into()
            } else {
                "warning".into()
            },
            duration_ms: 0,
        });

        // Webmail internal HTTP
        let webmail_ok = vm.webmail_internal_code >= 200 && vm.webmail_internal_code < 400;
        health.internals.push(MailCheck {
            name: "webmail internal HTTP".into(),
            passed: webmail_ok,
            details: format!("HTTP {}", vm.webmail_internal_code),
            severity: if webmail_ok {
                "info".into()
            } else {
                "warning".into()
            },
            duration_ms: 0,
        });

        // Mail queue
        let queue = vm.mail_queue.unwrap_or(0);
        let queue_ok = queue < 50;
        health.internals.push(MailCheck {
            name: "mail queue".into(),
            passed: queue_ok,
            details: format!("{} messages queued", queue),
            severity: if !queue_ok {
                "warning".into()
            } else {
                "info".into()
            },
            duration_ms: 0,
        });

        // Mail delivered/failed stats
        let delivered = vm.mail_delivered.unwrap_or(0);
        let failed = vm.mail_failed.unwrap_or(0);
        let ratio_ok = failed == 0 || (delivered > 0 && (failed as f64 / delivered as f64) < 0.1);
        health.internals.push(MailCheck {
            name: "mail delivery stats".into(),
            passed: ratio_ok,
            details: format!("{} delivered, {} failed (24h)", delivered, failed),
            severity: if !ratio_ok {
                "warning".into()
            } else {
                "info".into()
            },
            duration_ms: 0,
        });
    } else {
        // oci-mail VM not found in collected data
        health.containers.push(MailCheck {
            name: "oci-mail VM".into(),
            passed: false,
            details: "oci-mail VM not found in collected VM data".into(),
            severity: "critical".into(),
            duration_ms: 0,
        });
    }

    recompute_summary(health);
}

// ── Outbound path checks ────────────────────────────────────────────

async fn check_outbound_path() -> Vec<MailCheck> {
    let (maddy_smtps, oci_relay, aws_relay) = tokio::join!(
        tcp_check(
            "Maddy :465 SMTPS",
            MAIL_WG_IP,
            465,
            "critical",
        ),
        tcp_check(
            "OCI relay :587",
            "smtp.email.eu-marseille-1.oci.oraclecloud.com",
            587,
            "critical",
        ),
        tcp_check(
            "AWS relay :587 (fallback)",
            "email-smtp.us-east-1.amazonaws.com",
            587,
            "warning",
        ),
    );

    vec![maddy_smtps, oci_relay, aws_relay]
}

// ── Inbound path checks ─────────────────────────────────────────────

async fn check_inbound_path() -> Vec<MailCheck> {
    let (mx_dns, smtp_https, hickory_dns, http_to_smtp_proxy_api, maddy_25, imap_993) = tokio::join!(
        check_mx_dns(),
        check_smtp_https(),
        check_hickory_dns(),
        tcp_check("http-to-smtp-proxy-api :8080", PROXY_WG_IP, 8080, "critical"),
        tcp_check("Maddy :25", MAIL_WG_IP, 25, "critical"),
        tcp_check("IMAP :993", MAIL_WG_IP, 993, "critical"),
    );

    vec![mx_dns, smtp_https, hickory_dns, http_to_smtp_proxy_api, maddy_25, imap_993]
}

// ── DNS auth checks ─────────────────────────────────────────────────

async fn check_dns_auth() -> Vec<MailCheck> {
    let (mx, dkim, spf, dmarc) = tokio::join!(
        check_dns_mx(),
        check_dns_dkim(),
        check_dns_spf(),
        check_dns_dmarc(),
    );

    vec![mx, dkim, spf, dmarc]
}

// ── TLS port checks ─────────────────────────────────────────────────

async fn check_tls_ports() -> Vec<MailCheck> {
    let (imap_tls, smtps_tls, starttls) = tokio::join!(
        openssl_check(
            "IMAP TLS :993",
            MAIL_DOMAIN,
            993,
            false,
        ),
        openssl_check(
            "SMTPS :465",
            MAIL_DOMAIN,
            465,
            false,
        ),
        openssl_check(
            "STARTTLS :587",
            MAIL_DOMAIN,
            587,
            true,
        ),
    );

    vec![imap_tls, smtps_tls, starttls]
}

// ── Helper: TCP port probe ──────────────────────────────────────────

async fn tcp_check(name: &str, host: &str, port: u16, severity: &str) -> MailCheck {
    let start = Instant::now();

    // Try to parse as direct IP first, otherwise resolve
    let addr_result = if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        Ok(SocketAddr::new(ip, port))
    } else {
        // DNS resolve for hostnames
        match tokio::net::lookup_host(format!("{}:{}", host, port)).await {
            Ok(mut addrs) => addrs.next().ok_or("no addresses resolved"),
            Err(_) => Err("DNS resolution failed"),
        }
    };

    let duration_ms = start.elapsed().as_millis() as u64;

    let addr = match addr_result {
        Ok(a) => a,
        Err(e) => {
            return MailCheck {
                name: name.into(),
                passed: false,
                details: format!("{}:{} - {}", host, port, e),
                severity: severity.into(),
                duration_ms,
            };
        }
    };

    let connect_start = Instant::now();
    let result = timeout(TCP_TIMEOUT, TcpStream::connect(addr)).await;
    let total_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(_stream)) => MailCheck {
            name: name.into(),
            passed: true,
            details: format!(
                "{}:{} connected in {}ms",
                host,
                port,
                connect_start.elapsed().as_millis()
            ),
            severity: "info".into(),
            duration_ms: total_ms,
        },
        Ok(Err(e)) => MailCheck {
            name: name.into(),
            passed: false,
            details: format!("{}:{} connection refused: {}", host, port, e),
            severity: severity.into(),
            duration_ms: total_ms,
        },
        Err(_) => MailCheck {
            name: name.into(),
            passed: false,
            details: format!("{}:{} timeout after {}ms", host, port, TCP_TIMEOUT.as_millis()),
            severity: severity.into(),
            duration_ms: total_ms,
        },
    }
}

// ── Helper: DNS MX record check ─────────────────────────────────────

async fn check_mx_dns() -> MailCheck {
    let start = Instant::now();
    let resolver = public_resolver();

    let result = timeout(DNS_TIMEOUT, resolver.mx_lookup(BASE_DOMAIN)).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(mx)) => {
            let records: Vec<String> = mx
                .iter()
                .map(|m| format!("{} {}", m.preference(), m.exchange()))
                .collect();
            let passed = !records.is_empty();
            MailCheck {
                name: "MX DNS record".into(),
                passed,
                details: if passed {
                    records.join(", ")
                } else {
                    "no MX records found".into()
                },
                severity: if passed {
                    "info".into()
                } else {
                    "critical".into()
                },
                duration_ms,
            }
        }
        Ok(Err(e)) => MailCheck {
            name: "MX DNS record".into(),
            passed: false,
            details: format!("MX lookup failed: {}", e),
            severity: "critical".into(),
            duration_ms,
        },
        Err(_) => MailCheck {
            name: "MX DNS record".into(),
            passed: false,
            details: "MX lookup timed out".into(),
            severity: "critical".into(),
            duration_ms,
        },
    }
}

// ── Helper: SMTP HTTPS (CF Worker -> Caddy chain) ───────────────────

async fn check_smtp_https() -> MailCheck {
    let start = Instant::now();
    let client = reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();

    let url = format!("https://smtp.{}", BASE_DOMAIN);
    let result = timeout(HTTP_TIMEOUT, client.get(&url).send()).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(resp)) => {
            let status = resp.status().as_u16();
            // Any HTTP response means the chain is up (200, 301, 302, 403 all valid)
            let passed = status > 0;
            MailCheck {
                name: "smtp HTTPS (CF Worker chain)".into(),
                passed,
                details: format!("{} -> HTTP {}", url, status),
                severity: if passed {
                    "info".into()
                } else {
                    "critical".into()
                },
                duration_ms,
            }
        }
        Ok(Err(e)) => MailCheck {
            name: "smtp HTTPS (CF Worker chain)".into(),
            passed: false,
            details: format!("{} -> {}", url, e),
            severity: "critical".into(),
            duration_ms,
        },
        Err(_) => MailCheck {
            name: "smtp HTTPS (CF Worker chain)".into(),
            passed: false,
            details: format!("{} -> timeout", url),
            severity: "critical".into(),
            duration_ms,
        },
    }
}

// ── Helper: Hickory DNS resolves http-to-smtp-proxy-api.app ─────────────────────

async fn check_hickory_dns() -> MailCheck {
    let start = Instant::now();

    // Use Hickory at 10.0.0.1:53 as the resolver
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        format!("{}:53", HICKORY_IP).parse().unwrap(),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(3);
    let resolver = TokioAsyncResolver::tokio(rc, opts);

    let result = timeout(DNS_TIMEOUT, resolver.lookup_ip("http-to-smtp-proxy-api.app")).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(lookup)) => {
            let ips: Vec<String> = lookup.iter().map(|ip| ip.to_string()).collect();
            let passed = !ips.is_empty();
            MailCheck {
                name: "Hickory DNS http-to-smtp-proxy-api.app".into(),
                passed,
                details: if passed {
                    format!("resolved to {}", ips.join(", "))
                } else {
                    "no results".into()
                },
                severity: if passed {
                    "info".into()
                } else {
                    "warning".into()
                },
                duration_ms,
            }
        }
        Ok(Err(e)) => MailCheck {
            name: "Hickory DNS http-to-smtp-proxy-api.app".into(),
            passed: false,
            details: format!("lookup failed: {}", e),
            severity: "warning".into(),
            duration_ms,
        },
        Err(_) => MailCheck {
            name: "Hickory DNS http-to-smtp-proxy-api.app".into(),
            passed: false,
            details: format!("lookup timed out ({}:53)", HICKORY_IP),
            severity: "warning".into(),
            duration_ms,
        },
    }
}

// ── Helper: DNS auth record checks (public DNS 1.1.1.1) ────────────

async fn check_dns_mx() -> MailCheck {
    let start = Instant::now();
    let resolver = public_resolver();

    let result = timeout(DNS_TIMEOUT, resolver.mx_lookup(BASE_DOMAIN)).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(mx)) => {
            let records: Vec<String> = mx
                .iter()
                .map(|m| format!("{} {}", m.preference(), m.exchange()))
                .collect();
            MailCheck {
                name: "MX record".into(),
                passed: !records.is_empty(),
                details: records.join(", "),
                severity: if records.is_empty() {
                    "critical".into()
                } else {
                    "info".into()
                },
                duration_ms,
            }
        }
        _ => MailCheck {
            name: "MX record".into(),
            passed: false,
            details: "MX lookup failed".into(),
            severity: "critical".into(),
            duration_ms,
        },
    }
}

async fn check_dns_dkim() -> MailCheck {
    let start = Instant::now();
    let resolver = public_resolver();

    let query = format!("dkim._domainkey.{}", BASE_DOMAIN);
    let result = timeout(DNS_TIMEOUT, resolver.txt_lookup(&query)).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(txt)) => {
            let record = txt.iter().next().map(|t| t.to_string());
            let passed = record.is_some();
            MailCheck {
                name: "DKIM record".into(),
                passed,
                details: record
                    .map(|r| {
                        if r.len() > 60 {
                            format!("{}...", &r[..60])
                        } else {
                            r
                        }
                    })
                    .unwrap_or_else(|| "no DKIM TXT record found".into()),
                severity: if passed {
                    "info".into()
                } else {
                    "critical".into()
                },
                duration_ms,
            }
        }
        _ => MailCheck {
            name: "DKIM record".into(),
            passed: false,
            details: format!("{} lookup failed", query),
            severity: "critical".into(),
            duration_ms,
        },
    }
}

async fn check_dns_spf() -> MailCheck {
    let start = Instant::now();
    let resolver = public_resolver();

    let result = timeout(DNS_TIMEOUT, resolver.txt_lookup(BASE_DOMAIN)).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(txt)) => {
            let spf = txt
                .iter()
                .find(|t| t.to_string().contains("v=spf1"))
                .map(|t| t.to_string());
            let passed = spf.is_some();
            MailCheck {
                name: "SPF record".into(),
                passed,
                details: spf.unwrap_or_else(|| "no SPF TXT record found".into()),
                severity: if passed {
                    "info".into()
                } else {
                    "critical".into()
                },
                duration_ms,
            }
        }
        _ => MailCheck {
            name: "SPF record".into(),
            passed: false,
            details: "TXT lookup failed".into(),
            severity: "critical".into(),
            duration_ms,
        },
    }
}

async fn check_dns_dmarc() -> MailCheck {
    let start = Instant::now();
    let resolver = public_resolver();

    let query = format!("_dmarc.{}", BASE_DOMAIN);
    let result = timeout(DNS_TIMEOUT, resolver.txt_lookup(&query)).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(txt)) => {
            let dmarc = txt
                .iter()
                .find(|t| t.to_string().contains("v=DMARC1"))
                .map(|t| t.to_string());
            let passed = dmarc.is_some();
            MailCheck {
                name: "DMARC record".into(),
                passed,
                details: dmarc.unwrap_or_else(|| "no DMARC TXT record found".into()),
                severity: if passed {
                    "info".into()
                } else {
                    "warning".into()
                },
                duration_ms,
            }
        }
        _ => MailCheck {
            name: "DMARC record".into(),
            passed: false,
            details: format!("{} lookup failed", query),
            severity: "warning".into(),
            duration_ms,
        },
    }
}

// ── Stalwart + JMAP checks ──────────────────────────────────────

async fn check_stalwart() -> Vec<MailCheck> {
    // All Stalwart checks run in parallel
    let (smtp, smtps, submission, imaps, https_jmap, sieve,
         tls_imaps, tls_smtps, tls_sub, tls_jmap,
         jmap_wellknown, jmap_webadmin) = tokio::join!(
        // TCP port probes (via WG IP)
        tcp_check("Stalwart :2025 SMTP", MAIL_WG_IP, 2025, "warning"),
        tcp_check("Stalwart :2465 SMTPS", MAIL_WG_IP, 2465, "warning"),
        tcp_check("Stalwart :2587 Submission", MAIL_WG_IP, 2587, "warning"),
        tcp_check("Stalwart :2993 IMAPS", MAIL_WG_IP, 2993, "warning"),
        tcp_check("Stalwart :2443 HTTPS/JMAP", MAIL_WG_IP, 2443, "warning"),
        tcp_check("Stalwart :6190 ManageSieve", MAIL_WG_IP, 6190, "warning"),
        // TLS via public Caddy L4 passthrough
        openssl_check("Stalwart IMAPS TLS :2993", MAIL_DOMAIN, 2993, false),
        openssl_check("Stalwart SMTPS TLS :2465", MAIL_DOMAIN, 2465, false),
        openssl_check("Stalwart STARTTLS :2587", MAIL_DOMAIN, 2587, true),
        openssl_check("Stalwart HTTPS/JMAP TLS :2443", STALWART_DOMAIN, 2443, false),
        // JMAP endpoints
        check_jmap_wellknown(),
        check_jmap_webadmin(),
    );

    vec![
        smtp, smtps, submission, imaps, https_jmap, sieve,
        tls_imaps, tls_smtps, tls_sub, tls_jmap,
        jmap_wellknown, jmap_webadmin,
    ]
}

async fn check_jmap_wellknown() -> MailCheck {
    let start = Instant::now();
    let client = reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()
        .unwrap();

    let url = format!("https://{}/.well-known/jmap", STALWART_DOMAIN);
    let result = timeout(HTTP_TIMEOUT, client.get(&url).send()).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(resp)) => {
            let status = resp.status().as_u16();
            // JMAP well-known returns JSON with capabilities; 200 = healthy, 401/403 = auth required but alive
            let passed = matches!(status, 200 | 401 | 403);
            let body_preview = if status == 200 {
                resp.text().await.ok()
                    .and_then(|t| {
                        if t.contains("capabilities") || t.contains("urn:ietf:params:jmap") {
                            Some("JMAP capabilities present".to_string())
                        } else {
                            Some(format!("HTTP 200 ({}B)", t.len()))
                        }
                    })
                    .unwrap_or_else(|| "HTTP 200".into())
            } else {
                format!("HTTP {} (endpoint alive)", status)
            };
            MailCheck {
                name: "JMAP .well-known".into(),
                passed,
                details: body_preview,
                severity: if passed { "info".into() } else { "warning".into() },
                duration_ms,
            }
        }
        Ok(Err(e)) => MailCheck {
            name: "JMAP .well-known".into(),
            passed: false,
            details: format!("{} -> {}", url, e),
            severity: "warning".into(),
            duration_ms,
        },
        Err(_) => MailCheck {
            name: "JMAP .well-known".into(),
            passed: false,
            details: format!("{} -> timeout", url),
            severity: "warning".into(),
            duration_ms,
        },
    }
}

async fn check_jmap_webadmin() -> MailCheck {
    let start = Instant::now();
    let client = reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();

    let url = format!("https://{}/", STALWART_DOMAIN);
    let result = timeout(HTTP_TIMEOUT, client.get(&url).send()).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(resp)) => {
            let status = resp.status().as_u16();
            // Any HTTP response means Stalwart webadmin is alive
            let passed = status > 0 && status < 500;
            MailCheck {
                name: "Stalwart webadmin".into(),
                passed,
                details: format!("HTTP {} ({})", status, if passed { "alive" } else { "error" }),
                severity: if passed { "info".into() } else { "warning".into() },
                duration_ms,
            }
        }
        Ok(Err(e)) => MailCheck {
            name: "Stalwart webadmin".into(),
            passed: false,
            details: format!("{} -> {}", url, e),
            severity: "warning".into(),
            duration_ms,
        },
        Err(_) => MailCheck {
            name: "Stalwart webadmin".into(),
            passed: false,
            details: format!("{} -> timeout", url),
            severity: "warning".into(),
            duration_ms,
        },
    }
}

// ── Helper: TLS checks via openssl subprocess ───────────────────────

async fn openssl_check(name: &str, domain: &str, port: u16, starttls: bool) -> MailCheck {
    let start = Instant::now();

    let connect_arg = format!("{}:{}", domain, port);
    let mut args = vec![
        "s_client".to_string(),
        "-connect".to_string(),
        connect_arg.clone(),
        "-servername".to_string(),
        domain.to_string(),
    ];

    if starttls {
        args.push("-starttls".into());
        args.push("smtp".into());
    }

    let result = timeout(
        TLS_TIMEOUT,
        tokio::process::Command::new("openssl")
            .args(&args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output(),
    )
    .await;

    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok(output)) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            let combined = format!("{}\n{}", stdout, stderr);

            // Look for successful TLS handshake indicators
            let has_cert = combined.contains("BEGIN CERTIFICATE")
                || combined.contains("subject=")
                || combined.contains("issuer=");
            let has_protocol = combined.contains("Protocol")
                || combined.contains("TLSv1.2")
                || combined.contains("TLSv1.3");
            let verify_ok = combined.contains("Verify return code: 0");

            let passed = has_cert && (has_protocol || verify_ok);

            // Extract useful details
            let detail = if passed {
                let protocol = combined
                    .lines()
                    .find(|l| l.trim().starts_with("Protocol"))
                    .map(|l| l.trim().to_string())
                    .unwrap_or_default();
                let cipher = combined
                    .lines()
                    .find(|l| l.trim().starts_with("Cipher"))
                    .map(|l| l.trim().to_string())
                    .unwrap_or_default();
                format!(
                    "{} TLS OK{}{}",
                    connect_arg,
                    if protocol.is_empty() {
                        String::new()
                    } else {
                        format!(", {}", protocol)
                    },
                    if cipher.is_empty() {
                        String::new()
                    } else {
                        format!(", {}", cipher)
                    },
                )
            } else {
                // Extract error info
                let error_line = combined
                    .lines()
                    .find(|l| {
                        l.contains("error")
                            || l.contains("errno")
                            || l.contains("connect:") && l.contains("fail")
                    })
                    .unwrap_or("TLS handshake failed");
                format!("{} -> {}", connect_arg, error_line.trim())
            };

            MailCheck {
                name: name.into(),
                passed,
                details: detail,
                severity: if passed {
                    "info".into()
                } else {
                    "critical".into()
                },
                duration_ms,
            }
        }
        Ok(Err(e)) => MailCheck {
            name: name.into(),
            passed: false,
            details: format!("{} -> openssl error: {}", connect_arg, e),
            severity: "critical".into(),
            duration_ms,
        },
        Err(_) => MailCheck {
            name: name.into(),
            passed: false,
            details: format!("{} -> timeout after {}ms", connect_arg, TLS_TIMEOUT.as_millis()),
            severity: "critical".into(),
            duration_ms,
        },
    }
}

// ── Helper: public DNS resolver (1.1.1.1) ───────────────────────────

fn public_resolver() -> TokioAsyncResolver {
    let mut rc = ResolverConfig::new();
    rc.add_name_server(NameServerConfig::new(
        "1.1.1.1:53".parse().unwrap(),
        Protocol::Udp,
    ));
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(3);
    TokioAsyncResolver::tokio(rc, opts)
}

// ── Helper: recompute summary from all check vectors ────────────────

fn recompute_summary(health: &mut MailHealthData) {
    let all_checks: Vec<&MailCheck> = health
        .outbound_path
        .iter()
        .chain(health.inbound_path.iter())
        .chain(health.dns_auth.iter())
        .chain(health.tls_ports.iter())
        .chain(health.containers.iter())
        .chain(health.internals.iter())
        .chain(health.stalwart.iter())
        .collect();

    let total = all_checks.len();
    let passed = all_checks.iter().filter(|c| c.passed).count();
    let failed = total - passed;
    let critical = all_checks
        .iter()
        .filter(|c| !c.passed && c.severity == "critical")
        .count();
    let warnings = all_checks
        .iter()
        .filter(|c| !c.passed && c.severity == "warning")
        .count();

    health.summary = MailHealthSummary {
        total,
        passed,
        failed,
        critical,
        warnings,
    };
}
