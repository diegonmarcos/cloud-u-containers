use crate::types::{ExportedContainer, YaraHit};
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::types::{Check, Severity};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Instant;
use walkdir::WalkDir;

/// Docker rules path (container runtime)
const DOCKER_RULES_PATH: &str = "/usr/local/share/yara-rules";
/// Local dev rules path (relative to crate root)
const LOCAL_RULES_PATH: &str = "yara-rules";

/// Find the YARA rules directory
fn find_rules_path() -> Option<String> {
    if Path::new(DOCKER_RULES_PATH).is_dir() {
        return Some(DOCKER_RULES_PATH.to_string());
    }
    if Path::new(LOCAL_RULES_PATH).is_dir() {
        return Some(LOCAL_RULES_PATH.to_string());
    }
    None
}

/// Scan all exported containers with YARA rules
pub async fn scan_all(
    exports: &[ExportedContainer],
    caps: &RuntimeCapabilities,
    enabled: bool,
) -> (Vec<Check>, Vec<YaraHit>) {
    let mut checks = Vec::new();
    let mut hits = Vec::new();

    if !enabled {
        checks.push(Check {
            name: "YARA scan".into(),
            passed: true,
            details: "Disabled via cloud-data-sec-scan.json (phases.yara_enabled=false)".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, hits);
    }

    if !caps.yara_available {
        checks.push(Check {
            name: "YARA scan".into(),
            passed: true,
            details: "Skipped — YARA binary not available".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, hits);
    }

    let rules_path = match find_rules_path() {
        Some(p) => p,
        None => {
            checks.push(Check {
                name: "YARA rules".into(),
                passed: false,
                details: "No YARA rules directory found".into(),
                duration_ms: 0,
                error: Some("Checked /usr/local/share/yara-rules and yara-rules/".into()),
                severity: Severity::Warning,
            });
            return (checks, hits);
        }
    };

    // Collect all .yar files recursively
    let rule_files: Vec<String> = WalkDir::new(&rules_path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_type().is_file()
                && e.path()
                    .extension()
                    .map(|ext| ext == "yar" || ext == "yara")
                    .unwrap_or(false)
        })
        .map(|e| e.path().to_string_lossy().to_string())
        .collect();

    if rule_files.is_empty() {
        checks.push(Check {
            name: "YARA rules".into(),
            passed: false,
            details: format!("No .yar files found in {}", rules_path),
            duration_ms: 0,
            error: None,
            severity: Severity::Warning,
        });
        return (checks, hits);
    }

    checks.push(Check {
        name: "YARA rules loaded".into(),
        passed: true,
        details: format!("{} rule files from {}", rule_files.len(), rules_path),
        duration_ms: 0,
        error: None,
        severity: Severity::Info,
    });

    if exports.is_empty() {
        checks.push(Check {
            name: "YARA scan".into(),
            passed: true,
            details: "No exported containers to scan".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, hits);
    }

    // Scan each export directory with each rule file
    for export in exports {
        let t = Instant::now();
        let mut container_hits = Vec::new();

        for rule_file in &rule_files {
            match run_yara(rule_file, &export.export_path).await {
                Ok(yara_hits) => {
                    for (rule_name, file_path) in yara_hits {
                        let (hash, size) = file_hash_and_size(&file_path);
                        let severity = classify_yara_severity(&rule_name);
                        container_hits.push(YaraHit {
                            vm: export.vm_alias.clone(),
                            container: export.container_name.clone(),
                            file_path: file_path.clone(),
                            rule_name: rule_name.clone(),
                            severity: severity.clone(),
                            file_hash: hash,
                            file_size: size,
                        });
                    }
                }
                Err(e) => {
                    eprintln!(
                        "  YARA error scanning {}:{} with {}: {}",
                        export.vm_alias, export.container_name, rule_file, e
                    );
                }
            }
        }

        let ms = t.elapsed().as_millis() as u64;
        let hit_count = container_hits.len();

        if hit_count > 0 {
            checks.push(Check {
                name: format!("YARA {}:{}", export.vm_alias, export.container_name),
                passed: false,
                details: format!("{} matches found", hit_count),
                duration_ms: ms,
                error: None,
                severity: if container_hits.iter().any(|h| h.severity == "critical") {
                    Severity::Critical
                } else {
                    Severity::Warning
                },
            });
        } else {
            checks.push(Check {
                name: format!("YARA {}:{}", export.vm_alias, export.container_name),
                passed: true,
                details: "Clean — no matches".into(),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
        }

        hits.extend(container_hits);
    }

    (checks, hits)
}

/// Run YARA CLI against a directory and parse output
async fn run_yara(rule_file: &str, scan_dir: &str) -> anyhow::Result<Vec<(String, String)>> {
    let output = tokio::process::Command::new("yara")
        .args(["-r", "-s", rule_file, scan_dir])
        .output()
        .await?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut results = Vec::new();

    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("0x") {
            // Skip hex offset lines from -s flag (string match details)
            continue;
        }
        // Format: RULE_NAME FILE_PATH
        let parts: Vec<&str> = line.splitn(2, ' ').collect();
        if parts.len() == 2 {
            let rule_name = parts[0].to_string();
            let file_path = parts[1].to_string();
            results.push((rule_name, file_path));
        }
    }

    Ok(results)
}

/// Compute SHA256 hash and file size
fn file_hash_and_size(path: &str) -> (String, u64) {
    match std::fs::read(path) {
        Ok(data) => {
            let size = data.len() as u64;
            let mut hasher = Sha256::new();
            hasher.update(&data);
            let hash = hex::encode(hasher.finalize());
            (hash, size)
        }
        Err(_) => ("(unreadable)".into(), 0),
    }
}

/// Classify YARA rule severity based on rule name patterns
fn classify_yara_severity(rule_name: &str) -> String {
    let lower = rule_name.to_lowercase();
    if lower.contains("cryptominer")
        || lower.contains("webshell")
        || lower.contains("reverse_shell")
        || lower.contains("docker_escape")
        || lower.contains("container_escape")
    {
        "critical".into()
    } else if lower.contains("suspicious")
        || lower.contains("credential")
        || lower.contains("persistence")
    {
        "warning".into()
    } else {
        "info".into()
    }
}
