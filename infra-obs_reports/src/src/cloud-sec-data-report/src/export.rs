use crate::context::SecDataContext;
use crate::scan_config::ScanConfig;
use crate::types::ExportedContainer;
use futures::stream::{self, StreamExt};
use reports_common::capabilities::RuntimeCapabilities;
use reports_common::ssh;
use reports_common::types::{Check, Severity};
use std::time::Instant;
use tempfile::TempDir;
use walkdir::WalkDir;

/// Check if a container name looks like a database
fn is_database(name: &str, patterns: &[String]) -> bool {
    let lower = name.to_lowercase();
    patterns.iter().any(|p| lower.contains(p.as_str()))
}

/// Export container filesystems from all VMs and collect evidence directories.
///
/// Runs VMs in parallel (buffer_unordered = cfg.concurrency.vm_parallel) and
/// containers inside each VM in parallel (buffer_unordered = cfg.concurrency.container_parallel).
/// Per-container dir exports run serially so outstanding SSH channels per host
/// stay at cfg.concurrency.container_parallel (well under MaxSessions).
pub async fn export_all(
    ctx: &SecDataContext,
    caps: &RuntimeCapabilities,
) -> (Vec<Check>, Vec<ExportedContainer>, Vec<(String, String)>) {
    let mut checks = Vec::new();
    let mut exports = Vec::new();
    let mut evidence_dirs: Vec<(String, String)> = Vec::new();

    if !caps.ssh_available || !caps.wg_up {
        checks.push(Check {
            name: "Container export".into(),
            passed: true,
            details: "Skipped — no SSH/WG connectivity".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return (checks, exports, evidence_dirs);
    }

    // Pre-warm SSH ControlMaster mux per VM so simultaneous channels don't race.
    let _ = stream::iter(ctx.vms.iter())
        .map(|vm| async { ssh::ssh_echo_test(&vm.alias).await })
        .buffer_unordered(ctx.scan.concurrency.vm_parallel)
        .collect::<Vec<_>>()
        .await;

    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let cfg = &ctx.scan;

    let per_vm = stream::iter(ctx.vms.iter())
        .map(|vm| {
            let today = today.clone();
            async move { process_vm(&vm.alias, &today, cfg).await }
        })
        .buffer_unordered(cfg.concurrency.vm_parallel)
        .collect::<Vec<_>>()
        .await;

    for (vm_checks, vm_exports, vm_evidence) in per_vm {
        checks.extend(vm_checks);
        exports.extend(vm_exports);
        evidence_dirs.extend(vm_evidence);
    }

    (checks, exports, evidence_dirs)
}

/// Process a single VM: evidence vault + container exports.
async fn process_vm(
    vm_alias: &str,
    today: &str,
    cfg: &ScanConfig,
) -> (Vec<Check>, Vec<ExportedContainer>, Vec<(String, String)>) {
    let mut checks = Vec::new();
    let mut evidence_dirs: Vec<(String, String)> = Vec::new();

    let t = Instant::now();
    let evidence_result = try_evidence_vault(vm_alias, today, &cfg.evidence_files).await;
    if let Some((ev_checks, ev_path)) = evidence_result {
        let ms = t.elapsed().as_millis() as u64;
        checks.extend(ev_checks);
        checks.push(Check {
            name: format!("Evidence {}", vm_alias),
            passed: true,
            details: format!("Evidence vault snapshot downloaded ({})", ev_path),
            duration_ms: ms,
            error: None,
            severity: Severity::Info,
        });
        evidence_dirs.push((vm_alias.to_string(), ev_path));
    } else {
        let ms = t.elapsed().as_millis() as u64;
        checks.push(Check {
            name: format!("Evidence {}", vm_alias),
            passed: true,
            details: "No evidence vault snapshot — using docker cp fallback".into(),
            duration_ms: ms,
            error: None,
            severity: Severity::Info,
        });
    }

    // docker cp fallback: uses the VM's docker daemon to tar up container
    // filesystems over SSH. That's CPU load on the VM — gated off by default,
    // re-enable only on VMs that can spare it.
    let exports = if !cfg.phases.docker_cp_fallback_enabled {
        checks.push(Check {
            name: format!("Export {}", vm_alias),
            passed: true,
            details: "Skipped — docker_cp_fallback disabled (evidence-vault only)".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        Vec::new()
    } else {
        let t2 = Instant::now();
        match export_vm(vm_alias, cfg).await {
            Ok((mut vm_checks, vm_exports)) => {
                let ms = t2.elapsed().as_millis() as u64;
                checks.push(Check {
                    name: format!("Export {}", vm_alias),
                    passed: true,
                    details: format!(
                        "{} containers exported ({} files)",
                        vm_exports.len(),
                        vm_exports.iter().map(|e| e.file_count).sum::<usize>()
                    ),
                    duration_ms: ms,
                    error: None,
                    severity: Severity::Info,
                });
                checks.append(&mut vm_checks);
                vm_exports
            }
            Err(e) => {
                let ms = t2.elapsed().as_millis() as u64;
                checks.push(Check {
                    name: format!("Export {}", vm_alias),
                    passed: false,
                    details: format!("Failed: {}", e),
                    duration_ms: ms,
                    error: Some(e.to_string()),
                    severity: Severity::Warning,
                });
                Vec::new()
            }
        }
    };

    (checks, exports, evidence_dirs)
}

/// Try to fetch evidence snapshot from the vault on a VM.
/// Returns Some((checks, local_path)) if evidence exists, None otherwise.
async fn try_evidence_vault(
    vm_alias: &str,
    today: &str,
    evidence_files: &[String],
) -> Option<(Vec<Check>, String)> {
    let remote_dir = format!("/var/backups/evidence/{}", today);
    let mut checks = Vec::new();

    let ls_result = ssh::ssh_exec(
        vm_alias,
        &format!("ls {} 2>/dev/null && echo EXISTS", remote_dir),
        10,
    )
    .await;

    let exists = match &ls_result {
        Ok(output) => output.contains("EXISTS"),
        Err(_) => false,
    };

    if !exists {
        return None;
    }

    let tmpdir = match TempDir::new() {
        Ok(d) => d,
        Err(_) => return None,
    };
    let local_path = tmpdir.path().to_string_lossy().to_string();

    // Parallel download of evidence files — all small text/json.
    let downloads = stream::iter(evidence_files.iter())
        .map(|file_name| {
            let remote_path = format!("{}/{}", remote_dir, file_name);
            let local_file = format!("{}/{}", local_path, file_name);
            async move {
                let cmd = format!("cat {} 2>/dev/null", remote_path);
                let result = ssh::ssh_exec_raw(vm_alias, &cmd, 30).await;
                match result {
                    Ok(data) if !data.is_empty() => {
                        std::fs::write(&local_file, &data).is_ok()
                    }
                    _ => false,
                }
            }
        })
        .buffer_unordered(evidence_files.len().max(1))
        .collect::<Vec<_>>()
        .await;
    let downloaded = downloads.into_iter().filter(|ok| *ok).count();

    if downloaded == 0 {
        return None;
    }

    checks.push(Check {
        name: format!("Evidence files {}", vm_alias),
        passed: true,
        details: format!(
            "{}/{} evidence files downloaded from {}",
            downloaded,
            evidence_files.len(),
            remote_dir
        ),
        duration_ms: 0,
        error: None,
        severity: Severity::Info,
    });

    let _ = tmpdir.keep();

    Some((checks, local_path))
}

/// Export containers from a single VM (containers in parallel).
async fn export_vm(
    vm_alias: &str,
    cfg: &ScanConfig,
) -> anyhow::Result<(Vec<Check>, Vec<ExportedContainer>)> {
    let mut checks = Vec::new();

    let output = ssh::ssh_exec(vm_alias, "docker ps --format '{{.Names}}'", 15).await?;
    let containers: Vec<String> = output
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();

    if containers.is_empty() {
        checks.push(Check {
            name: format!("{}: no containers", vm_alias),
            passed: true,
            details: "No running containers found".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return Ok((checks, Vec::new()));
    }

    let results = stream::iter(containers.into_iter())
        .map(|container| {
            let cfg = cfg.clone();
            async move {
                if is_database(&container, &cfg.targets.skip_db_patterns) {
                    return (
                        Check {
                            name: format!("{}:{}", vm_alias, container),
                            passed: true,
                            details: "Skipped (database container)".into(),
                            duration_ms: 0,
                            error: None,
                            severity: Severity::Info,
                        },
                        None,
                    );
                }

                let t = Instant::now();
                match export_container(vm_alias, &container, &cfg).await {
                    Ok(exported) => {
                        let ms = t.elapsed().as_millis() as u64;
                        let check = Check {
                            name: format!("{}:{}", vm_alias, container),
                            passed: true,
                            details: format!(
                                "{} files, {} bytes",
                                exported.file_count, exported.total_bytes
                            ),
                            duration_ms: ms,
                            error: None,
                            severity: Severity::Info,
                        };
                        (check, Some(exported))
                    }
                    Err(e) => {
                        let ms = t.elapsed().as_millis() as u64;
                        let check = Check {
                            name: format!("{}:{}", vm_alias, container),
                            passed: false,
                            details: format!("Export failed: {}", e),
                            duration_ms: ms,
                            error: Some(e.to_string()),
                            severity: Severity::Warning,
                        };
                        (check, None)
                    }
                }
            }
        })
        .buffer_unordered(cfg.concurrency.container_parallel)
        .collect::<Vec<_>>()
        .await;

    let mut exports = Vec::with_capacity(results.len());
    for (check, maybe_export) in results {
        checks.push(check);
        if let Some(e) = maybe_export {
            exports.push(e);
        }
    }

    Ok((checks, exports))
}

/// Export a single container's key config files to a tempdir.
/// Uses `docker cp` for selective extraction (avoids full `docker export` which OOMs E2 Micros).
/// Dirs are fetched serially per container to bound outstanding SSH channels per host.
async fn export_container(
    vm_alias: &str,
    container: &str,
    cfg: &ScanConfig,
) -> anyhow::Result<ExportedContainer> {
    let tmpdir = TempDir::new()?;
    let tmppath = tmpdir.path().to_string_lossy().to_string();

    let mut total_file_count = 0usize;
    let mut total_bytes = 0u64;

    for dir in &cfg.targets.scan_dirs {
        let local_dir = format!("{}/{}", tmppath, dir.replace('/', "_"));
        let _ = std::fs::create_dir_all(&local_dir);

        let cmd = format!(
            "docker cp {}:/{} - 2>/dev/null | head -c {} || true",
            container, dir, cfg.limits.max_bytes_per_dir
        );
        let raw_data = ssh::ssh_exec_raw(vm_alias, &cmd, cfg.limits.ssh_timeout_secs)
            .await
            .unwrap_or_default();

        if raw_data.len() > 10 {
            let tar_path = format!("{}/tmp.tar", local_dir);
            std::fs::write(&tar_path, &raw_data)?;

            let _ = std::process::Command::new("tar")
                .args(["xf", &tar_path, "-C", &local_dir])
                .status();

            let _ = std::fs::remove_file(&tar_path);

            let (fc, fb) = count_dir_stats(&local_dir);
            total_file_count += fc;
            total_bytes += fb;
        }
    }

    let path = tmpdir.path().to_string_lossy().to_string();
    let _ = tmpdir.keep();

    Ok(ExportedContainer {
        vm_alias: vm_alias.to_string(),
        container_name: container.to_string(),
        export_path: path,
        file_count: total_file_count,
        total_bytes,
    })
}

/// Count files and total bytes in a directory
fn count_dir_stats(dir: &str) -> (usize, u64) {
    let mut count = 0usize;
    let mut bytes = 0u64;
    for entry in WalkDir::new(dir).into_iter().filter_map(|e| e.ok()) {
        if entry.file_type().is_file() {
            count += 1;
            bytes += entry.metadata().map(|m| m.len()).unwrap_or(0);
        }
    }
    (count, bytes)
}

/// Clean up all exported temp directories and evidence dirs
pub fn cleanup(exports: &[ExportedContainer]) {
    for export in exports {
        if std::path::Path::new(&export.export_path).exists() {
            if let Err(e) = std::fs::remove_dir_all(&export.export_path) {
                eprintln!(
                    "  Warning: failed to cleanup {}: {}",
                    export.export_path, e
                );
            }
        }
    }
}

/// Clean up evidence directories
pub fn cleanup_evidence(evidence_dirs: &[(String, String)]) {
    for (_vm, path) in evidence_dirs {
        if std::path::Path::new(path).exists() {
            if let Err(e) = std::fs::remove_dir_all(path) {
                eprintln!("  Warning: failed to cleanup evidence {}: {}", path, e);
            }
        }
    }
}
