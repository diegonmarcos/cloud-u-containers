use crate::types::DiffChange;
use reports_common::types::{Check, Severity};
use std::path::Path;
use std::time::Instant;

/// Analyze diff data from evidence snapshots.
/// Each entry in `evidence_dirs` is (vm_alias, evidence_dir_path).
pub fn analyze_diffs(evidence_dirs: &[(String, String)]) -> (Vec<Check>, Vec<DiffChange>) {
    let mut checks = Vec::new();
    let mut changes = Vec::new();

    if evidence_dirs.is_empty() {
        checks.push(Check {
            name: "Diff analysis".into(),
            passed: true,
            details: "No evidence directories available".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, changes);
    }

    for (vm_alias, evidence_dir) in evidence_dirs {
        let t = Instant::now();
        let diff_path = Path::new(evidence_dir).join("diff.json");

        if !diff_path.exists() {
            let ms = t.elapsed().as_millis() as u64;
            checks.push(Check {
                name: format!("Diff {}", vm_alias),
                passed: true,
                details: "No diff data available".into(),
                duration_ms: ms,
                error: None,
                severity: Severity::Info,
            });
            continue;
        }

        match parse_diff(&diff_path, vm_alias) {
            Ok(vm_changes) => {
                let ms = t.elapsed().as_millis() as u64;
                let change_count = vm_changes.len();
                let new_count = vm_changes.iter().filter(|c| c.change_type == "new").count();
                let modified_count = vm_changes
                    .iter()
                    .filter(|c| c.change_type == "modified")
                    .count();
                let deleted_count = vm_changes
                    .iter()
                    .filter(|c| c.change_type == "deleted")
                    .count();

                let has_new = new_count > 0;
                let has_critical_change = new_count > 3 || deleted_count > 3;

                checks.push(Check {
                    name: format!("Diff {}", vm_alias),
                    passed: !has_critical_change,
                    details: if change_count == 0 {
                        "No container changes detected".into()
                    } else {
                        format!(
                            "{} changes: {} new, {} modified, {} deleted",
                            change_count, new_count, modified_count, deleted_count
                        )
                    },
                    duration_ms: ms,
                    error: None,
                    severity: if has_critical_change {
                        Severity::Warning
                    } else if has_new {
                        Severity::Info
                    } else {
                        Severity::Info
                    },
                });
                changes.extend(vm_changes);
            }
            Err(e) => {
                let ms = t.elapsed().as_millis() as u64;
                checks.push(Check {
                    name: format!("Diff {}", vm_alias),
                    passed: false,
                    details: format!("Parse error: {}", e),
                    duration_ms: ms,
                    error: Some(e.to_string()),
                    severity: Severity::Warning,
                });
            }
        }
    }

    (checks, changes)
}

/// Parse a diff.json file and extract container changes.
///
/// Expected diff.json format (from evidence collector):
/// ```json
/// {
///   "containers": {
///     "new": [{"name": "...", "image": "...", "sha256": "..."}],
///     "modified": [{"name": "...", "previous_sha256": "...", "current_sha256": "..."}],
///     "deleted": [{"name": "...", "image": "..."}]
///   },
///   "system": {
///     "modified": true/false,
///     "details": "..."
///   }
/// }
/// ```
fn parse_diff(path: &Path, vm_alias: &str) -> anyhow::Result<Vec<DiffChange>> {
    let data = std::fs::read_to_string(path)?;
    let json: serde_json::Value = serde_json::from_str(&data)?;
    let mut changes = Vec::new();

    // Parse container changes
    let containers = &json["containers"];

    // New containers
    if let Some(new_arr) = containers["new"].as_array() {
        for entry in new_arr {
            let name = entry["name"]
                .as_str()
                .or_else(|| entry["container_name"].as_str())
                .unwrap_or("unknown")
                .to_string();
            let image = entry["image"].as_str().unwrap_or("unknown");
            changes.push(DiffChange {
                vm: vm_alias.to_string(),
                container: name,
                change_type: "new".into(),
                details: format!("New container (image: {})", image),
            });
        }
    }

    // Modified containers
    if let Some(mod_arr) = containers["modified"].as_array() {
        for entry in mod_arr {
            let name = entry["name"]
                .as_str()
                .or_else(|| entry["container_name"].as_str())
                .unwrap_or("unknown")
                .to_string();
            let prev = entry["previous_sha256"].as_str().unwrap_or("?");
            let curr = entry["current_sha256"].as_str().unwrap_or("?");
            changes.push(DiffChange {
                vm: vm_alias.to_string(),
                container: name,
                change_type: "modified".into(),
                details: format!(
                    "SHA256 changed: {}.. -> {}..",
                    &prev[..prev.len().min(12)],
                    &curr[..curr.len().min(12)]
                ),
            });
        }
    }

    // Deleted containers
    if let Some(del_arr) = containers["deleted"].as_array() {
        for entry in del_arr {
            let name = entry["name"]
                .as_str()
                .or_else(|| entry["container_name"].as_str())
                .unwrap_or("unknown")
                .to_string();
            let image = entry["image"].as_str().unwrap_or("unknown");
            changes.push(DiffChange {
                vm: vm_alias.to_string(),
                container: name,
                change_type: "deleted".into(),
                details: format!("Container removed (was image: {})", image),
            });
        }
    }

    // System archive changes
    if let Some(system) = json.get("system") {
        if system["modified"].as_bool().unwrap_or(false) {
            let detail = system["details"]
                .as_str()
                .unwrap_or("System archive modified");
            changes.push(DiffChange {
                vm: vm_alias.to_string(),
                container: "(system)".into(),
                change_type: "modified".into(),
                details: detail.to_string(),
            });
        }
    }

    Ok(changes)
}
