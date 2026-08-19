use crate::context::SecDataContext;
use crate::types::SiemAlert;
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::checks::auth_client;
use reports_common::types::{Check, Severity};
use std::time::Instant;

/// Fetch SIEM alerts and stats
pub async fn fetch_all(
    ctx: &SecDataContext,
    caps: &RuntimeCapabilities,
) -> (Vec<Check>, Vec<SiemAlert>) {
    let mut checks = Vec::new();
    let mut alerts = Vec::new();

    let token = match &caps.bearer_token {
        Some(t) => t.clone(),
        None => {
            checks.push(Check {
                name: "SIEM API auth".into(),
                passed: true,
                details: "Skipped — no bearer token available".into(),
                duration_ms: 0,
                error: None,
                severity: Severity::Info,
            });
            return (checks, alerts);
        }
    };

    let client = auth_client(&token);
    let base_url = &ctx.siem_api_url;

    // Fetch alerts from last 24h
    let t = Instant::now();
    let since = chrono::Utc::now()
        .checked_sub_signed(chrono::Duration::hours(24))
        .unwrap_or_else(chrono::Utc::now)
        .to_rfc3339();
    let alerts_url = format!("{}/api/alerts?since={}&limit=1000", base_url, since);

    match client.get(&alerts_url).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let ms = t.elapsed().as_millis() as u64;

            if status >= 200 && status < 300 {
                match resp.json::<serde_json::Value>().await {
                    Ok(body) => {
                        let parsed = parse_alerts(&body);
                        let count = parsed.len();
                        alerts.extend(parsed);
                        checks.push(Check {
                            name: "SIEM alerts".into(),
                            passed: true,
                            details: format!("{} alerts in last 24h", count),
                            duration_ms: ms,
                            error: None,
                            severity: Severity::Info,
                        });
                    }
                    Err(e) => {
                        checks.push(Check {
                            name: "SIEM alerts".into(),
                            passed: false,
                            details: format!("JSON parse error: {}", e),
                            duration_ms: ms,
                            error: Some(e.to_string()),
                            severity: Severity::Warning,
                        });
                    }
                }
            } else {
                checks.push(Check {
                    name: "SIEM alerts".into(),
                    passed: false,
                    details: format!("HTTP {}", status),
                    duration_ms: ms,
                    error: Some(format!("SIEM API returned {}", status)),
                    severity: Severity::Warning,
                });
            }
        }
        Err(e) => {
            let ms = t.elapsed().as_millis() as u64;
            checks.push(Check {
                name: "SIEM alerts".into(),
                passed: true,
                details: format!("SIEM API unreachable: {}", e),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
        }
    }

    // Fetch SIEM stats
    let t = Instant::now();
    let stats_url = format!("{}/api/stats", base_url);
    match client.get(&stats_url).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let ms = t.elapsed().as_millis() as u64;
            if status >= 200 && status < 300 {
                checks.push(Check {
                    name: "SIEM stats".into(),
                    passed: true,
                    details: format!("Stats endpoint OK (HTTP {})", status),
                    duration_ms: ms,
                    error: None,
                    severity: Severity::Info,
                });
            } else {
                checks.push(Check {
                    name: "SIEM stats".into(),
                    passed: false,
                    details: format!("HTTP {}", status),
                    duration_ms: ms,
                    error: Some(format!("Stats endpoint returned {}", status)),
                    severity: Severity::Warning,
                });
            }
        }
        Err(e) => {
            let ms = t.elapsed().as_millis() as u64;
            checks.push(Check {
                name: "SIEM stats".into(),
                passed: true,
                details: format!("Unreachable: {}", e),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
        }
    }

    // Fetch SIEM VM inventory
    let t = Instant::now();
    let vms_url = format!("{}/api/vms", base_url);
    match client.get(&vms_url).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let ms = t.elapsed().as_millis() as u64;
            if status >= 200 && status < 300 {
                checks.push(Check {
                    name: "SIEM VMs".into(),
                    passed: true,
                    details: format!("VM inventory OK (HTTP {})", status),
                    duration_ms: ms,
                    error: None,
                    severity: Severity::Info,
                });
            } else {
                checks.push(Check {
                    name: "SIEM VMs".into(),
                    passed: false,
                    details: format!("HTTP {}", status),
                    duration_ms: ms,
                    error: Some(format!("VMs endpoint returned {}", status)),
                    severity: Severity::Warning,
                });
            }
        }
        Err(e) => {
            let ms = t.elapsed().as_millis() as u64;
            checks.push(Check {
                name: "SIEM VMs".into(),
                passed: true,
                details: format!("Unreachable: {}", e),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
        }
    }

    (checks, alerts)
}

/// Parse SIEM alerts from JSON response
fn parse_alerts(body: &serde_json::Value) -> Vec<SiemAlert> {
    let mut alerts = Vec::new();

    // Try array at root or under "alerts" key
    let items = body
        .as_array()
        .or_else(|| body["alerts"].as_array())
        .or_else(|| body["data"].as_array());

    let Some(items) = items else {
        return alerts;
    };

    for item in items {
        alerts.push(SiemAlert {
            timestamp: item["timestamp"]
                .as_str()
                .or_else(|| item["time"].as_str())
                .unwrap_or("")
                .to_string(),
            vm: item["vm"]
                .as_str()
                .or_else(|| item["host"].as_str())
                .unwrap_or("")
                .to_string(),
            severity: item["severity"]
                .as_str()
                .or_else(|| item["level"].as_str())
                .unwrap_or("info")
                .to_string(),
            rule: item["rule"]
                .as_str()
                .or_else(|| item["rule_name"].as_str())
                .unwrap_or("")
                .to_string(),
            file: item["file"]
                .as_str()
                .or_else(|| item["path"].as_str())
                .unwrap_or("")
                .to_string(),
        });
    }

    alerts
}
