//! Evidence writer — Phase 2 of the unified report+collector design.
//!
//! Every time the report SSHes a VM and gets back the giant `===SECTION===`
//! batch output, this module writes each section to disk under the declared
//! `output_dir` from cloud-data-reports-logs.json. Result: after a single
//! report run, `reports-logs/dist/vms/<vm>/` already contains:
//!   - meta.json           (vm name, ts, reachable)
//!   - <section>.txt       (one per ===SECTION=== marker — UPTIME, DISK,
//!                          CONTAINER_FULL, WG_PEERS, FAILED_UNITS, ...)
//!   - docker_ps.json      (CONTAINER_FULL parsed back to docker-ps schema)
//!
//! The bash collector's docker.sh / systemd.sh / network.sh modules become
//! redundant for these sections — they were re-collecting via fresh SSH
//! sessions data the report ALREADY had in memory. This eliminates the
//! ~200 duplicate SSH handshakes per debug cycle.
//!
//! Failure here is NEVER fatal to the report — if disk is full, permissions
//! are wrong, or output_dir misconfigured, the report logs a warning and
//! proceeds. The evidence side-effect is best-effort; the report's analysis
//! must complete regardless.

use reports_common::context::find_cloud_data_file;
use serde_json::json;
use std::fs;
use std::path::PathBuf;

/// Resolve the evidence root directory (cloud-data-reports-logs.json:.output_dir).
/// Falls back to reports-logs/dist relative to the cloud-data repo root if
/// the config can't be found — same convention all consumers already use.
fn evidence_root() -> Option<PathBuf> {
    let cfg_path = find_cloud_data_file("cloud-data-reports-logs.json")?;
    let raw = fs::read_to_string(&cfg_path).ok()?;
    let cfg: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let out_dir = cfg.get("output_dir")?.as_str()?;
    // output_dir is repo-relative ("reports-logs/dist"); join against the
    // cloud-data repo root, which is the directory containing the config.
    let repo_root = cfg_path.parent()?;
    Some(repo_root.join(out_dir))
}

/// Split the giant SSH batch output by `===NAME===` headers and yield
/// (name, body) pairs. Body excludes the trailing `===END===` sentinel.
fn split_sections(raw: &str) -> Vec<(String, String)> {
    let mut sections: Vec<(String, String)> = Vec::new();
    let mut cur_name: Option<String> = None;
    let mut cur_body = String::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("===").and_then(|s| s.strip_suffix("===")) {
            // Flush previous section
            if let Some(name) = cur_name.take() {
                if name != "END" {
                    sections.push((name, std::mem::take(&mut cur_body)));
                }
            }
            cur_name = Some(rest.to_string());
            cur_body.clear();
        } else if cur_name.is_some() {
            cur_body.push_str(line);
            cur_body.push('\n');
        }
    }
    if let Some(name) = cur_name {
        if name != "END" {
            sections.push((name, cur_body));
        }
    }
    sections
}

/// Convert CONTAINER_FULL pipe-delim section to docker_ps.json shape.
/// Each line: `<name>|<image>|<status>|<running_for>|<created>`.
/// Output array of objects matching `docker ps --format '{{json .}}'`
/// shape (Names, Image, Status, RunningFor, CreatedAt). The bash
/// docker.sh module emits this exact schema; preserving it lets
/// reports-logs/index.sh continue to work unchanged.
fn container_full_to_docker_ps(body: &str) -> serde_json::Value {
    let arr: Vec<serde_json::Value> = body
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| {
            let parts: Vec<&str> = l.split('|').collect();
            if parts.len() < 4 { return None; }
            Some(json!({
                "Names":      parts[0],
                "Image":      parts[1],
                "Status":     parts[2],
                "RunningFor": parts[3],
                "CreatedAt":  parts.get(4).copied().unwrap_or(""),
                "Labels":     "",
            }))
        })
        .collect();
    serde_json::Value::Array(arr)
}

/// Write one VM's evidence to disk. Best-effort: errors print a stderr
/// warning but never propagate — the report's analysis must complete
/// regardless of evidence-side issues.
pub fn write_vm_evidence(vm_name: &str, raw: &str, reachable: bool) {
    let root = match evidence_root() {
        Some(r) => r,
        None => {
            eprintln!("[evidence] {} skipped — cloud-data-reports-logs.json not found", vm_name);
            return;
        }
    };
    let vm_dir = root.join("vms").join(vm_name);
    if let Err(e) = fs::create_dir_all(&vm_dir) {
        eprintln!("[evidence] {} mkdir failed: {}", vm_name, e);
        return;
    }

    // meta.json — vm + timestamp + reachable + container_count (best effort)
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let sections = split_sections(raw);
    let container_count: usize = sections
        .iter()
        .find(|(n, _)| n == "CONTAINER_FULL")
        .map(|(_, b)| b.lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0);

    let meta = json!({
        "vm":              vm_name,
        "reachable":       reachable,
        "ts":              now,
        "container_count": container_count,
        "source":          "cloud-health-full-daily/evidence (single-pass writer)",
    });
    let _ = fs::write(vm_dir.join("meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default());

    if !reachable {
        return;
    }

    // Per-section text dumps — every ===SECTION=== gets its own file.
    let mut written = 0usize;
    for (name, body) in &sections {
        let safe = name.to_lowercase().replace('.', "_");
        let path = vm_dir.join(format!("{}.txt", safe));
        if let Err(e) = fs::write(&path, body) {
            eprintln!("[evidence] {}/{}.txt write failed: {}", vm_name, safe, e);
        } else {
            written += 1;
        }
    }

    // docker_ps.json — derive from CONTAINER_FULL so reports-logs/index.sh
    // and the bash docker.sh can still consume the old schema unchanged.
    if let Some((_, body)) = sections.iter().find(|(n, _)| n == "CONTAINER_FULL") {
        let docker_ps = container_full_to_docker_ps(body);
        let _ = fs::write(
            vm_dir.join("docker_ps.json"),
            serde_json::to_string_pretty(&docker_ps).unwrap_or("[]".into()),
        );
    }

    eprintln!("[evidence] {} → {} ({} sections, {} containers)",
              vm_name, vm_dir.display(), written, container_count);
}

/// Phase 2 active-path writer — for the rsync VmBatchData flow used by
/// health_full2/layers.rs::layer_platform. Receives the structured
/// payload already produced by `/opt/health/latest.json` on the VM,
/// plus the raw JSON, and materialises:
///   meta.json          — vm + ts + source + reachable + container_count
///   health_latest.json — verbatim raw JSON from the rsync (full source-of-truth)
///   docker_ps.json     — schema-compatible array derived from containers[]
///
/// Best-effort, non-fatal — same contract as write_vm_evidence.
pub fn write_vm_evidence_from_rsync(
    vm_alias: &str,
    raw_json: Option<&serde_json::Value>,
    container_count: usize,
    reachable: bool,
) {
    let root = match evidence_root() {
        Some(r) => r,
        None => {
            eprintln!("[evidence] {} skipped — cloud-data-reports-logs.json not found", vm_alias);
            return;
        }
    };
    let vm_dir = root.join("vms").join(vm_alias);
    if let Err(e) = fs::create_dir_all(&vm_dir) {
        eprintln!("[evidence] {} mkdir failed: {}", vm_alias, e);
        return;
    }

    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let meta = json!({
        "vm":              vm_alias,
        "reachable":       reachable,
        "ts":              now,
        "container_count": container_count,
        "source":          "cloud-health-full-daily/evidence (rsync /opt/health/latest.json)",
    });
    let _ = fs::write(vm_dir.join("meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default());

    if !reachable {
        return;
    }

    // Verbatim raw JSON — the source of truth /opt/health/latest.json
    if let Some(raw) = raw_json {
        let _ = fs::write(
            vm_dir.join("health_latest.json"),
            serde_json::to_string_pretty(raw).unwrap_or("{}".into()),
        );
    }

    // docker_ps.json — derive from containers[] in the raw JSON so that
    // reports-logs/index.sh + reports-logs/dist/containers/<svc>/<ctr>/
    // consumers keep working without code changes.
    let containers_arr = raw_json
        .and_then(|j| j.get("containers"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let docker_ps: Vec<serde_json::Value> = containers_arr
        .iter()
        .filter_map(|c| {
            let name = c.get("name")?.as_str()?;
            let image = c.get("image").and_then(|v| v.as_str()).unwrap_or("?");
            let status = c.get("status").and_then(|v| v.as_str()).unwrap_or("?");
            let health = c.get("health").and_then(|v| v.as_str()).unwrap_or("none");
            Some(json!({
                "Names":  name,
                "Image":  image,
                "Status": status,
                "Health": health,
                "Labels": "",
            }))
        })
        .collect();
    let _ = fs::write(
        vm_dir.join("docker_ps.json"),
        serde_json::to_string_pretty(&docker_ps).unwrap_or("[]".into()),
    );

    eprintln!("[evidence] {} → {} ({} containers, source=rsync)",
              vm_alias, vm_dir.display(), container_count);
}
