use crate::types::RuntimeIssue;
use reports_common::types::{Check, Severity};
use serde::Deserialize;
use std::collections::HashSet;
use std::path::Path;
use std::time::Instant;

/// Data-driven allowlist for capability/privileged findings that are
/// genuinely required and already minimized (e.g. cap_add:SYS_ADMIN instead
/// of privileged:true). Loaded from build-reports.json:.runtime_allowlist
/// (source: 2_configs/src/inputs/reports-runtime-allowlist.json). An entry
/// downgrades its matching (vm, container, category) finding to Info rather
/// than dropping it, so a future accidental widening is still visible.
#[derive(Debug, Deserialize)]
struct RuntimeAllowlistEntry {
    vm: String,
    container: String,
    category: String,
    #[allow(dead_code)]
    reason: String,
}

#[derive(Debug, Deserialize, Default)]
struct RuntimeAllowlistConfig {
    #[serde(default)]
    entries: Vec<RuntimeAllowlistEntry>,
}

fn load_runtime_allowlist() -> HashSet<(String, String, String)> {
    let cfg: RuntimeAllowlistConfig = reports_common::context::load_build_reports_section("runtime_allowlist")
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default();
    cfg.entries
        .into_iter()
        .map(|e| (e.vm, e.container, e.category))
        .collect()
}

/// Analyze runtime security posture from evidence snapshots.
/// Each entry in `evidence_dirs` is (vm_alias, evidence_dir_path).
pub async fn analyze_runtime(
    evidence_dirs: &[(String, String)],
) -> (Vec<Check>, Vec<RuntimeIssue>) {
    let allowlist = load_runtime_allowlist();
    let mut checks = Vec::new();
    let mut issues = Vec::new();

    if evidence_dirs.is_empty() {
        checks.push(Check {
            name: "Runtime analysis".into(),
            passed: true,
            details: "No evidence directories available".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, issues);
    }

    for (vm_alias, evidence_dir) in evidence_dirs {
        let t = Instant::now();
        let mut vm_issues = Vec::new();
        let mut any_data = false;

        // Analyze docker-inspect.json
        let inspect_path = Path::new(evidence_dir).join("docker-inspect.json");
        if inspect_path.exists() {
            any_data = true;
            match analyze_docker_inspect(&inspect_path, vm_alias) {
                Ok(mut di_issues) => {
                    for issue in &mut di_issues {
                        let key = (issue.vm.clone(), issue.container_or_process.clone(), issue.category.clone());
                        if allowlist.contains(&key) {
                            issue.severity = "info".into();
                            issue.details = format!("{} (allowlisted: see reports-runtime-allowlist.json)", issue.details);
                        }
                    }
                    vm_issues.extend(di_issues);
                }
                Err(e) => {
                    eprintln!("  Warning: docker-inspect parse error on {}: {}", vm_alias, e);
                }
            }
        }

        // Analyze connections.txt
        let connections_path = Path::new(evidence_dir).join("connections.txt");
        if connections_path.exists() {
            any_data = true;
            match analyze_connections(&connections_path, vm_alias) {
                Ok(conn_issues) => vm_issues.extend(conn_issues),
                Err(e) => {
                    eprintln!("  Warning: connections parse error on {}: {}", vm_alias, e);
                }
            }
        }

        let ms = t.elapsed().as_millis() as u64;

        if !any_data {
            checks.push(Check {
                name: format!("Runtime {}", vm_alias),
                passed: true,
                details: "No runtime evidence files available".into(),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
            continue;
        }

        let has_critical = vm_issues.iter().any(|i| i.severity == "critical");
        let has_warning = vm_issues.iter().any(|i| i.severity == "warning");
        let issue_count = vm_issues.len();

        checks.push(Check {
            name: format!("Runtime {}", vm_alias),
            passed: !has_critical && !has_warning,
            details: if issue_count == 0 {
                "No runtime security issues".into()
            } else {
                format!("{} runtime issues detected", issue_count)
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

        issues.extend(vm_issues);
    }

    (checks, issues)
}

/// Analyze docker inspect output for privileged containers, host networking, dangerous capabilities.
fn analyze_docker_inspect(path: &Path, vm_alias: &str) -> anyhow::Result<Vec<RuntimeIssue>> {
    let data = std::fs::read_to_string(path)?;
    let containers: Vec<serde_json::Value> = match serde_json::from_str(&data) {
        Ok(v) => v,
        Err(_) => {
            // Try parsing as single object wrapped in array
            let single: serde_json::Value = serde_json::from_str(&data)?;
            if let Some(arr) = single.as_array() {
                arr.clone()
            } else {
                vec![single]
            }
        }
    };

    let mut issues = Vec::new();

    for container in &containers {
        let name = container["Name"]
            .as_str()
            .unwrap_or("")
            .trim_start_matches('/')
            .to_string();

        if name.is_empty() {
            continue;
        }

        let host_config = &container["HostConfig"];

        // Check privileged mode
        if host_config["Privileged"].as_bool().unwrap_or(false) {
            issues.push(RuntimeIssue {
                vm: vm_alias.to_string(),
                category: "privileged_container".into(),
                container_or_process: name.clone(),
                details: "Container running in privileged mode".into(),
                severity: "critical".into(),
            });
        }

        // Check host network mode
        if host_config["NetworkMode"].as_str().unwrap_or("") == "host" {
            issues.push(RuntimeIssue {
                vm: vm_alias.to_string(),
                category: "host_network".into(),
                container_or_process: name.clone(),
                details: "Container using host network mode".into(),
                severity: "warning".into(),
            });
        }

        // Check dangerous capabilities
        if let Some(cap_add) = host_config["CapAdd"].as_array() {
            for cap in cap_add {
                let cap_str = cap.as_str().unwrap_or("");
                if cap_str == "SYS_ADMIN" || cap_str == "ALL" {
                    issues.push(RuntimeIssue {
                        vm: vm_alias.to_string(),
                        category: "cap_sys_admin".into(),
                        container_or_process: name.clone(),
                        details: format!("Container has dangerous capability: {}", cap_str),
                        severity: "critical".into(),
                    });
                }
            }
        }

        // Check PID mode
        if host_config["PidMode"].as_str().unwrap_or("") == "host" {
            issues.push(RuntimeIssue {
                vm: vm_alias.to_string(),
                category: "host_network".into(),
                container_or_process: name.clone(),
                details: "Container using host PID namespace".into(),
                severity: "warning".into(),
            });
        }
    }

    Ok(issues)
}

/// Analyze network connections for suspicious outbound traffic.
fn analyze_connections(path: &Path, vm_alias: &str) -> anyhow::Result<Vec<RuntimeIssue>> {
    let data = std::fs::read_to_string(path)?;
    let mut issues = Vec::new();
    let mut suspicious_count = 0usize;

    for line in data.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("Proto") || line.starts_with("Active") {
            continue;
        }

        // Parse netstat/ss style output: proto recv-q send-q local foreign state
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 5 {
            continue;
        }

        // Look for ESTABLISHED connections to non-loopback, non-private IPs
        let state = parts.last().unwrap_or(&"");
        if *state != "ESTABLISHED" {
            continue;
        }

        let foreign = parts.get(4).or_else(|| parts.get(3)).unwrap_or(&"");
        if let Some(ip) = extract_ip(foreign) {
            if !is_private_or_loopback(&ip) {
                suspicious_count += 1;
                if issues.len() < 20 {
                    issues.push(RuntimeIssue {
                        vm: vm_alias.to_string(),
                        category: "suspicious_connection".into(),
                        container_or_process: "system".into(),
                        details: format!("Outbound ESTABLISHED to {}", foreign),
                        severity: "info".into(),
                    });
                }
            }
        }
    }

    // Elevate severity if many suspicious connections
    if suspicious_count > 20 {
        for issue in &mut issues {
            if issue.category == "suspicious_connection" {
                issue.severity = "warning".into();
            }
        }
    }

    Ok(issues)
}

/// Extract IP from a host:port string.
fn extract_ip(addr: &str) -> Option<String> {
    // Handle IPv4:port format (1.2.3.4:8080)
    if let Some(colon_idx) = addr.rfind(':') {
        let ip_part = &addr[..colon_idx];
        if !ip_part.is_empty() {
            return Some(ip_part.to_string());
        }
    }
    None
}

/// Check if an IP is private (RFC1918), loopback, or link-local.
fn is_private_or_loopback(ip: &str) -> bool {
    ip.starts_with("127.")
        || ip.starts_with("10.")
        || ip.starts_with("172.16.")
        || ip.starts_with("172.17.")
        || ip.starts_with("172.18.")
        || ip.starts_with("172.19.")
        || ip.starts_with("172.2")
        || ip.starts_with("172.3")
        || ip.starts_with("192.168.")
        || ip.starts_with("169.254.")
        || ip == "::1"
        || ip.starts_with("fe80:")
        || ip.starts_with("fc")
        || ip.starts_with("fd")
        || ip == "0.0.0.0"
        || ip == "::"
}
