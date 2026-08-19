use crate::types::{Correlation, DiffChange, JournalAlert, RuntimeIssue, SiemAlert, ThreatIntelMatch, YaraHit};
use reports_common::types::{Check, Severity};
use std::collections::{HashMap, HashSet};

/// Cross-correlate YARA hits, SIEM alerts, threat intel, journal alerts, runtime issues, and diff changes
pub fn correlate(
    yara_hits: &[YaraHit],
    siem_alerts: &[SiemAlert],
    ti_matches: &[ThreatIntelMatch],
    journal_alerts: &[JournalAlert],
    runtime_issues: &[RuntimeIssue],
    diff_changes: &[DiffChange],
) -> (Vec<Check>, Vec<Correlation>) {
    let mut checks = Vec::new();
    let mut correlations = Vec::new();

    // Pattern 1: YARA hit + SIEM alert on same VM = confirmed threat
    let yara_vms: HashSet<&str> = yara_hits.iter().map(|h| h.vm.as_str()).collect();
    let siem_vms: HashSet<&str> = siem_alerts.iter().map(|a| a.vm.as_str()).collect();
    let overlap_vms: Vec<&&str> = yara_vms.intersection(&siem_vms).collect();

    for vm in &overlap_vms {
        let vm_yara: Vec<&YaraHit> = yara_hits.iter().filter(|h| h.vm == ***vm).collect();
        let vm_siem: Vec<&SiemAlert> = siem_alerts.iter().filter(|a| a.vm == ***vm).collect();

        let evidence: Vec<String> = vm_yara
            .iter()
            .map(|h| format!("YARA: {} in {}:{}", h.rule_name, h.container, h.file_path))
            .chain(
                vm_siem
                    .iter()
                    .map(|a| format!("SIEM: {} at {}", a.rule, a.timestamp)),
            )
            .collect();

        correlations.push(Correlation {
            description: format!(
                "Confirmed threat on {}: YARA hit + SIEM alert",
                vm
            ),
            severity: "critical".into(),
            sources: vec!["yara".into(), "siem".into()],
            evidence,
        });
    }

    // Pattern 2: YARA hit hash matches threat intel = known malware
    let yara_hashes: HashSet<&str> = yara_hits
        .iter()
        .map(|h| h.file_hash.as_str())
        .filter(|h| !h.is_empty() && *h != "(unreadable)")
        .collect();

    let ti_indicators: HashSet<&str> = ti_matches
        .iter()
        .filter(|m| m.indicator_type == "hash" || m.indicator_type == "hash_match")
        .map(|m| m.indicator.as_str())
        .collect();

    let hash_overlap: Vec<&&str> = yara_hashes.intersection(&ti_indicators).collect();
    if !hash_overlap.is_empty() {
        let evidence: Vec<String> = hash_overlap
            .iter()
            .map(|h| {
                let hit = yara_hits.iter().find(|y| y.file_hash == ***h);
                match hit {
                    Some(y) => format!(
                        "Hash {} matched in {}:{} (rule: {})",
                        h, y.vm, y.file_path, y.rule_name
                    ),
                    None => format!("Hash {} matched threat intel", h),
                }
            })
            .collect();

        correlations.push(Correlation {
            description: format!(
                "Known malware detected: {} hash(es) match threat intel",
                hash_overlap.len()
            ),
            severity: "critical".into(),
            sources: vec!["yara".into(), "threat_intel".into()],
            evidence,
        });
    }

    // Pattern 3: Multiple YARA hits on same VM (>3) = systematic compromise
    let mut yara_by_vm: HashMap<&str, Vec<&YaraHit>> = HashMap::new();
    for hit in yara_hits {
        yara_by_vm.entry(hit.vm.as_str()).or_default().push(hit);
    }

    for (vm, hits) in &yara_by_vm {
        if hits.len() > 3 {
            let evidence: Vec<String> = hits
                .iter()
                .map(|h| {
                    format!(
                        "{}: {} ({})",
                        h.container, h.rule_name, h.file_path
                    )
                })
                .collect();

            correlations.push(Correlation {
                description: format!(
                    "Systematic compromise suspected on {}: {} YARA hits",
                    vm,
                    hits.len()
                ),
                severity: "warning".into(),
                sources: vec!["yara".into()],
                evidence,
            });
        }
    }

    // Pattern 4: SIEM alert spike (>10 in last hour) = active attack
    if siem_alerts.len() > 10 {
        let high_severity: Vec<&SiemAlert> = siem_alerts
            .iter()
            .filter(|a| {
                let s = a.severity.to_lowercase();
                s == "critical" || s == "high"
            })
            .collect();

        if high_severity.len() > 10 {
            let evidence: Vec<String> = high_severity
                .iter()
                .take(5)
                .map(|a| format!("{}: {} on {} ({})", a.timestamp, a.rule, a.vm, a.severity))
                .collect();

            correlations.push(Correlation {
                description: format!(
                    "Alert spike detected: {} high-severity SIEM alerts in 24h",
                    high_severity.len()
                ),
                severity: "warning".into(),
                sources: vec!["siem".into()],
                evidence,
            });
        }
    }

    // Pattern 5: YARA hit + journal SSH bruteforce on same VM = active compromise
    let journal_ssh_vms: HashSet<&str> = journal_alerts
        .iter()
        .filter(|a| a.category == "ssh_bruteforce" && a.count > 10)
        .map(|a| a.vm.as_str())
        .collect();

    let yara_and_ssh: Vec<&&str> = yara_vms.intersection(&journal_ssh_vms).collect();
    for vm in &yara_and_ssh {
        let vm_yara: Vec<&YaraHit> = yara_hits.iter().filter(|h| h.vm == ***vm).collect();
        let vm_ssh: Vec<&JournalAlert> = journal_alerts
            .iter()
            .filter(|a| a.vm == ***vm && a.category == "ssh_bruteforce")
            .collect();

        let evidence: Vec<String> = vm_yara
            .iter()
            .take(3)
            .map(|h| format!("YARA: {} in {}:{}", h.rule_name, h.container, h.file_path))
            .chain(
                vm_ssh
                    .iter()
                    .map(|a| format!("SSH bruteforce: {}", a.details)),
            )
            .collect();

        correlations.push(Correlation {
            description: format!(
                "Active compromise on {}: YARA hit + SSH bruteforce",
                vm
            ),
            severity: "critical".into(),
            sources: vec!["yara".into(), "journal".into()],
            evidence,
        });
    }

    // Pattern 6: New container in diff + no matching docker event in journal = stealth deployment
    let journal_docker_vms: HashSet<&str> = journal_alerts
        .iter()
        .filter(|a| a.category == "docker_event")
        .map(|a| a.vm.as_str())
        .collect();

    let new_containers: Vec<&DiffChange> = diff_changes
        .iter()
        .filter(|c| c.change_type == "new")
        .collect();

    for change in &new_containers {
        if !journal_docker_vms.contains(change.vm.as_str()) {
            correlations.push(Correlation {
                description: format!(
                    "Stealth deployment on {}: new container '{}' with no docker events in journal",
                    change.vm, change.container
                ),
                severity: "critical".into(),
                sources: vec!["diff".into(), "journal".into()],
                evidence: vec![
                    format!("New container: {} ({})", change.container, change.details),
                    format!("No docker lifecycle events in journal for {}", change.vm),
                ],
            });
        }
    }

    // Pattern 7: Runtime privileged container + YARA hit = critical
    let privileged_vms: HashSet<&str> = runtime_issues
        .iter()
        .filter(|i| i.category == "privileged_container" || i.category == "cap_sys_admin")
        .map(|i| i.vm.as_str())
        .collect();

    let priv_and_yara: Vec<&&str> = privileged_vms.intersection(&yara_vms).collect();
    for vm in &priv_and_yara {
        let vm_priv: Vec<&RuntimeIssue> = runtime_issues
            .iter()
            .filter(|i| {
                i.vm == ***vm
                    && (i.category == "privileged_container" || i.category == "cap_sys_admin")
            })
            .collect();
        let vm_yara: Vec<&YaraHit> = yara_hits.iter().filter(|h| h.vm == ***vm).collect();

        let evidence: Vec<String> = vm_priv
            .iter()
            .map(|i| format!("Privileged: {} ({})", i.container_or_process, i.details))
            .chain(
                vm_yara
                    .iter()
                    .take(3)
                    .map(|h| format!("YARA: {} in {}", h.rule_name, h.container)),
            )
            .collect();

        correlations.push(Correlation {
            description: format!(
                "Privileged container with malware on {}: escalation risk",
                vm
            ),
            severity: "critical".into(),
            sources: vec!["runtime".into(), "yara".into()],
            evidence,
        });
    }

    // Pattern 8: Journal OOM spike + many modified containers = resource exhaustion attack
    let oom_vms: HashSet<&str> = journal_alerts
        .iter()
        .filter(|a| a.category == "oom_kill" && a.count > 2)
        .map(|a| a.vm.as_str())
        .collect();

    let modified_by_vm: HashMap<&str, usize> = diff_changes
        .iter()
        .filter(|c| c.change_type == "modified")
        .fold(HashMap::new(), |mut acc, c| {
            *acc.entry(c.vm.as_str()).or_insert(0) += 1;
            acc
        });

    for vm in &oom_vms {
        let mod_count = modified_by_vm.get(*vm).copied().unwrap_or(0);
        if mod_count > 2 {
            let vm_oom: Vec<&JournalAlert> = journal_alerts
                .iter()
                .filter(|a| a.vm == **vm && a.category == "oom_kill")
                .collect();

            let evidence: Vec<String> = vm_oom
                .iter()
                .map(|a| format!("OOM: {} events — {}", a.count, a.details))
                .chain(std::iter::once(format!(
                    "Diff: {} containers modified",
                    mod_count
                )))
                .collect();

            correlations.push(Correlation {
                description: format!(
                    "Resource exhaustion suspected on {}: OOM kills + {} modified containers",
                    vm, mod_count
                ),
                severity: "warning".into(),
                sources: vec!["journal".into(), "diff".into()],
                evidence,
            });
        }
    }

    // Summary check
    if correlations.is_empty() {
        checks.push(Check {
            name: "Cross-correlation".into(),
            passed: true,
            details: "No correlated threats found".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
    } else {
        let critical_count = correlations
            .iter()
            .filter(|c| c.severity == "critical")
            .count();
        let warning_count = correlations
            .iter()
            .filter(|c| c.severity == "warning")
            .count();

        checks.push(Check {
            name: "Cross-correlation".into(),
            passed: false,
            details: format!(
                "{} correlations: {} critical, {} warning",
                correlations.len(),
                critical_count,
                warning_count,
            ),
            duration_ms: 0,
            error: None,
            severity: if critical_count > 0 {
                Severity::Critical
            } else {
                Severity::Warning
            },
        });
    }

    (checks, correlations)
}
