use crate::types::JournalAlert;
use flate2::read::GzDecoder;
use reports_common::types::{Check, Severity};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::time::Instant;

/// Analyze journal logs from evidence snapshots across all VMs.
/// Each entry in `evidence_dirs` is (vm_alias, evidence_dir_path).
pub async fn analyze_journals(
    evidence_dirs: &[(String, String)],
) -> (Vec<Check>, Vec<JournalAlert>) {
    let mut checks = Vec::new();
    let mut alerts = Vec::new();

    if evidence_dirs.is_empty() {
        checks.push(Check {
            name: "Journal analysis".into(),
            passed: true,
            details: "No evidence directories available".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, alerts);
    }

    for (vm_alias, evidence_dir) in evidence_dirs {
        let t = Instant::now();
        let journal_path = Path::new(evidence_dir).join("journal-24h.json.gz");

        if !journal_path.exists() {
            let ms = t.elapsed().as_millis() as u64;
            checks.push(Check {
                name: format!("Journal {}", vm_alias),
                passed: true,
                details: "No journal data available".into(),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
            continue;
        }

        match parse_journal_gz(&journal_path, vm_alias) {
            Ok(vm_alerts) => {
                let ms = t.elapsed().as_millis() as u64;
                let alert_count = vm_alerts.len();

                let has_critical = vm_alerts.iter().any(|a| a.severity == "critical");
                let has_warning = vm_alerts.iter().any(|a| a.severity == "warning");

                checks.push(Check {
                    name: format!("Journal {}", vm_alias),
                    passed: !has_critical && !has_warning,
                    details: if alert_count == 0 {
                        "No suspicious journal entries".into()
                    } else {
                        format!("{} alert categories detected", alert_count)
                    },
                    duration_ms: ms,
                    error: None,
                    severity: if has_critical {
                        Severity::Critical
                    } else if has_warning {
                        Severity::Warning
                    } else {
                        Severity::Info
                    },
                });
                alerts.extend(vm_alerts);
            }
            Err(e) => {
                let ms = t.elapsed().as_millis() as u64;
                checks.push(Check {
                    name: format!("Journal {}", vm_alias),
                    passed: false,
                    details: format!("Parse error: {}", e),
                    duration_ms: ms,
                    error: Some(e.to_string()),
                    severity: Severity::Warning,
                });
            }
        }
    }

    (checks, alerts)
}

/// Parse a gzipped journal file and extract security-relevant alerts.
fn parse_journal_gz(path: &Path, vm_alias: &str) -> anyhow::Result<Vec<JournalAlert>> {
    let file = std::fs::File::open(path)?;
    let decoder = GzDecoder::new(file);
    let reader = BufReader::new(decoder);

    let mut ssh_failed: HashMap<String, usize> = HashMap::new(); // source_ip -> count
    let mut docker_events: Vec<String> = Vec::new();
    let mut oom_kills: Vec<String> = Vec::new();
    let mut systemd_failures: Vec<String> = Vec::new();

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        if line.trim().is_empty() {
            continue;
        }

        let entry: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let message = entry["MESSAGE"]
            .as_str()
            .or_else(|| entry["message"].as_str())
            .unwrap_or("");
        let unit = entry["_SYSTEMD_UNIT"]
            .as_str()
            .or_else(|| entry["UNIT"].as_str())
            .unwrap_or("");
        let syslog_id = entry["SYSLOG_IDENTIFIER"]
            .as_str()
            .unwrap_or("");

        // SSH bruteforce detection
        if (syslog_id == "sshd" || unit.contains("sshd"))
            && (message.contains("Failed password") || message.contains("Invalid user"))
        {
            // Try to extract source IP from message
            let ip = extract_ip_from_ssh_message(message);
            *ssh_failed.entry(ip).or_insert(0) += 1;
        }

        // Docker events (container lifecycle not matching declared)
        if syslog_id == "dockerd" || syslog_id == "containerd" || unit.contains("docker") {
            if message.contains("die") || message.contains("kill") || message.contains("start") {
                if docker_events.len() < 100 {
                    docker_events.push(message.chars().take(200).collect());
                }
            }
        }

        // OOM kills
        if message.contains("oom_kill") || message.contains("Out of memory") || message.contains("OOM") {
            if oom_kills.len() < 50 {
                oom_kills.push(message.chars().take(200).collect());
            }
        }

        // Systemd unit failures
        if message.contains("Failed to start") || message.contains("entered failed state") {
            if systemd_failures.len() < 50 {
                let detail = if !unit.is_empty() {
                    format!("{}: {}", unit, &message[..message.len().min(150)])
                } else {
                    message.chars().take(200).collect()
                };
                systemd_failures.push(detail);
            }
        }
    }

    let mut alerts = Vec::new();

    // SSH bruteforce alerts
    let total_ssh_failures: usize = ssh_failed.values().sum();
    if total_ssh_failures > 0 {
        let top_ips: Vec<String> = {
            let mut sorted: Vec<_> = ssh_failed.iter().collect();
            sorted.sort_by(|a, b| b.1.cmp(a.1));
            sorted
                .iter()
                .take(5)
                .map(|(ip, count)| format!("{} ({}x)", ip, count))
                .collect()
        };

        let severity = if total_ssh_failures > 100 {
            "critical"
        } else if total_ssh_failures > 10 {
            "warning"
        } else {
            "info"
        };

        alerts.push(JournalAlert {
            vm: vm_alias.to_string(),
            category: "ssh_bruteforce".into(),
            count: total_ssh_failures,
            severity: severity.into(),
            details: format!(
                "{} failed SSH attempts from {} IPs. Top: {}",
                total_ssh_failures,
                ssh_failed.len(),
                top_ips.join(", ")
            ),
        });
    }

    // Docker event alerts
    if !docker_events.is_empty() {
        let severity = if docker_events.len() > 50 {
            "warning"
        } else {
            "info"
        };
        alerts.push(JournalAlert {
            vm: vm_alias.to_string(),
            category: "docker_event".into(),
            count: docker_events.len(),
            severity: severity.into(),
            details: format!(
                "{} docker lifecycle events (start/die/kill)",
                docker_events.len()
            ),
        });
    }

    // OOM kill alerts
    if !oom_kills.is_empty() {
        alerts.push(JournalAlert {
            vm: vm_alias.to_string(),
            category: "oom_kill".into(),
            count: oom_kills.len(),
            severity: "critical".into(),
            details: format!(
                "{} OOM kill events: {}",
                oom_kills.len(),
                oom_kills.first().unwrap_or(&String::new())
            ),
        });
    }

    // Systemd failure alerts
    if !systemd_failures.is_empty() {
        let severity = if systemd_failures.len() > 10 {
            "warning"
        } else {
            "info"
        };
        alerts.push(JournalAlert {
            vm: vm_alias.to_string(),
            category: "systemd_failure".into(),
            count: systemd_failures.len(),
            severity: severity.into(),
            details: format!(
                "{} systemd failures: {}",
                systemd_failures.len(),
                systemd_failures
                    .iter()
                    .take(3)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("; ")
            ),
        });
    }

    Ok(alerts)
}

/// Extract source IP from an SSH failure message.
/// Typical format: "Failed password for root from 1.2.3.4 port 22 ssh2"
fn extract_ip_from_ssh_message(message: &str) -> String {
    if let Some(from_idx) = message.find(" from ") {
        let after_from = &message[from_idx + 6..];
        if let Some(space_idx) = after_from.find(' ') {
            return after_from[..space_idx].to_string();
        }
        return after_from.to_string();
    }
    "unknown".to_string()
}
