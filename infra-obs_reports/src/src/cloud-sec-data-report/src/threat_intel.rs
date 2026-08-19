use crate::types::{ThreatIntelMatch, YaraHit};
use reports_common::types::{Check, Severity};
use std::collections::HashSet;
use std::time::Instant;

const URLHAUS_API: &str = "https://urlhaus.abuse.ch/downloads/json_recent/";

/// Fetch threat intelligence feeds and cross-match with YARA hits
pub async fn fetch_all() -> (Vec<Check>, Vec<ThreatIntelMatch>) {
    let mut checks = Vec::new();
    let mut matches = Vec::new();

    let t = Instant::now();

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());

    // Fetch URLhaus recent entries (public JSON download, no auth needed)
    match client
        .get(URLHAUS_API)
        .send()
        .await
    {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let ms = t.elapsed().as_millis() as u64;

            if status >= 200 && status < 300 {
                match resp.json::<serde_json::Value>().await {
                    Ok(body) => {
                        let parsed = parse_urlhaus(&body);
                        let count = parsed.len();
                        matches.extend(parsed);
                        checks.push(Check {
                            name: "URLhaus feed".into(),
                            passed: true,
                            details: format!("{} indicators fetched", count),
                            duration_ms: ms,
                            error: None,
                            severity: Severity::Info,
                        });
                    }
                    Err(e) => {
                        checks.push(Check {
                            name: "URLhaus feed".into(),
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
                    name: "URLhaus feed".into(),
                    passed: false,
                    details: format!("HTTP {}", status),
                    duration_ms: ms,
                    error: Some(format!("URLhaus returned {}", status)),
                    severity: Severity::Warning,
                });
            }
        }
        Err(e) => {
            let ms = t.elapsed().as_millis() as u64;
            checks.push(Check {
                name: "URLhaus feed".into(),
                passed: false,
                details: format!("Unreachable: {}", e),
                duration_ms: ms,
                error: Some(e.to_string()),
                severity: Severity::Warning,
            });
        }
    }

    (checks, matches)
}

/// Parse URLhaus JSON download into ThreatIntelMatch entries.
/// Format: {"12345": [{"url": "...", "threat": "...", ...}], "12346": [...]}
fn parse_urlhaus(body: &serde_json::Value) -> Vec<ThreatIntelMatch> {
    let mut matches = Vec::new();

    let Some(obj) = body.as_object() else {
        return matches;
    };

    // Each key is a numeric ID, value is an array of URL entries
    for (_id, entries) in obj.iter().take(200) {
        let Some(arr) = entries.as_array() else {
            continue;
        };
        for entry in arr {
            let url = entry["url"].as_str().unwrap_or("").to_string();
            let threat = entry["threat"]
                .as_str()
                .or_else(|| entry["url_status"].as_str())
                .unwrap_or("unknown")
                .to_string();

            if url.is_empty() {
                continue;
            }

            matches.push(ThreatIntelMatch {
                source: "URLhaus".into(),
                indicator: url,
                indicator_type: "url".into(),
                matched_in: threat,
                confidence: "medium".into(),
            });
        }
    }

    matches
}

/// Cross-match YARA hit hashes against threat intel indicators
pub fn cross_match(
    yara_hits: &[YaraHit],
    ti_matches: &[ThreatIntelMatch],
) -> Vec<ThreatIntelMatch> {
    let mut result = Vec::new();

    // Collect all hashes from YARA hits
    let yara_hashes: HashSet<&str> = yara_hits
        .iter()
        .map(|h| h.file_hash.as_str())
        .filter(|h| !h.is_empty() && *h != "(unreadable)")
        .collect();

    // Check if any threat intel indicators match YARA hashes
    for ti in ti_matches {
        if ti.indicator_type == "hash" && yara_hashes.contains(ti.indicator.as_str()) {
            result.push(ThreatIntelMatch {
                source: ti.source.clone(),
                indicator: ti.indicator.clone(),
                indicator_type: "hash_match".into(),
                matched_in: format!(
                    "YARA hit hash matches {} indicator",
                    ti.source
                ),
                confidence: "high".into(),
            });
        }
    }

    result
}
