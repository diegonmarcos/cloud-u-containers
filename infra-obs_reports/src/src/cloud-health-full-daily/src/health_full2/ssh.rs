use super::types::{ContainerHealth, VmBatchData};
use anyhow::Result;
use std::time::Duration;
use tokio::time::timeout;

const SSH_TIMEOUT: Duration = Duration::from_secs(10);
const RSYNC_TIMEOUT: Duration = Duration::from_secs(12);

/// Execute a command on a remote VM via SSH
#[allow(dead_code)]
pub async fn ssh_exec(vm_alias: &str, command: &str, timeout_secs: u64) -> Result<String> {
    let output = timeout(
        Duration::from_secs(timeout_secs),
        tokio::process::Command::new("ssh")
            .args([
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=/tmp/cloud-health-mux-%h",
                "-o", "ControlPersist=30",
                vm_alias,
                command,
            ])
            .output(),
    )
    .await??;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("SSH to {} failed: {}", vm_alias, stderr.trim())
    }
}

/// Rsync /opt/health/latest.json from VM to local cache, parse it.
/// This is the primary VM data collection method (rsync agent pattern).
pub async fn rsync_health(vm_alias: &str) -> Option<VmBatchData> {
    // CACHE_DIR is exported by the crate engine (points at the crate's cache/).
    // Falls back to cwd-relative "cache/" when running outside the engine.
    let cache_root = std::env::var("CACHE_DIR").unwrap_or_else(|_| "cache".to_string());
    let cache_dir = format!("{}/{}", cache_root, vm_alias);
    let _ = std::fs::create_dir_all(&cache_dir);
    let cache_file = format!("{}/latest.json", cache_dir);

    let rsync_ok = timeout(
        RSYNC_TIMEOUT,
        tokio::process::Command::new("rsync")
            .args([
                "-az",
                "-e",
                "ssh -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ControlMaster=auto -o ControlPath=/tmp/cloud-health-mux-%h -o ControlPersist=30 -o BatchMode=yes",
                &format!("{}:/opt/health/latest.json", vm_alias),
                &cache_file,
            ])
            .output(),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(|o| o.status.success())
    .unwrap_or(false);

    if !rsync_ok {
        return None;
    }

    let raw = std::fs::read_to_string(&cache_file).ok()?;
    let j: serde_json::Value = serde_json::from_str(&raw).ok()?;

    let mut data = VmBatchData {
        alias: vm_alias.to_string(),
        reachable: true,
        docker_version: j["docker_version"]
            .as_str()
            .unwrap_or("?")
            .to_string(),
        mem_used: format!("{}M", j["mem"]["used"].as_u64().unwrap_or(0)),
        mem_total: format!("{}M", j["mem"]["total"].as_u64().unwrap_or(0)),
        mem_pct: j["mem"]["pct"].as_u64().unwrap_or(0) as u32,
        swap: j["swap"]
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                format!(
                    "{}M/{}M",
                    j["swap"]["used"].as_u64().unwrap_or(0),
                    j["swap"]["total"].as_u64().unwrap_or(0)
                )
            }),
        disk_used: j["disk"]["used"].as_str().unwrap_or("?").to_string(),
        disk_total: j["disk"]["total"].as_str().unwrap_or("?").to_string(),
        disk_pct: j["disk"]["pct"].as_str().unwrap_or("?").to_string(),
        load: j["load"].as_str().unwrap_or("?").to_string(),
        uptime: j["uptime"].as_str().unwrap_or("?").to_string(),
        containers_total: j["containers_total"].as_u64().unwrap_or(0) as u32,
        containers_running: j["containers_running"].as_u64().unwrap_or(0) as u32,
        containers: Vec::new(),
        raw_json: Some(j.clone()),
    };

    if let Some(ctrs) = j["containers"].as_array() {
        for c in ctrs {
            let name = c["name"].as_str().unwrap_or("?").to_string();
            let status = c["status"].as_str().unwrap_or("?").to_string();
            let health = c["health"].as_str().unwrap_or("none").to_string();
            let image = c["image"].as_str().unwrap_or("?").to_string();
            let up = !status.starts_with("Exited") && !status.starts_with("Created");
            let healthy = health == "healthy";
            data.containers.push(ContainerHealth {
                name,
                up,
                healthy,
                status,
                health_state: health,
                image,
            });
        }
    }

    // Sort: exited first, then unhealthy, then starting, then up, then healthy
    data.containers.sort_by(|a, b| {
        let order = |h: &str| -> u8 {
            match h {
                "created" => 0,
                "exited" => 1,
                "unhealthy" => 2,
                "starting" => 3,
                "none" => 4,
                "healthy" => 5,
                _ => 9,
            }
        };
        order(&a.health_state).cmp(&order(&b.health_state))
    });

    Some(data)
}

/// SSH echo test — verifies SSH auth works
pub async fn ssh_echo_test(vm_alias: &str) -> bool {
    timeout(
        SSH_TIMEOUT,
        tokio::process::Command::new("ssh")
            .args([
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=/tmp/cloud-health-mux-%h",
                "-o", "ControlPersist=30",
                vm_alias,
                "echo OK",
            ])
            .output(),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).contains("OK"))
    .unwrap_or(false)
}

/// Parse ===section=== markers from SSH batch output (fallback)
#[allow(dead_code)]
pub fn parse_section(output: &str, name: &str) -> Option<String> {
    let start_marker = format!("==={}===", name);
    let end_marker_prefix = "===";
    let mut capturing = false;
    let mut lines = Vec::new();

    for line in output.lines() {
        if line.trim() == start_marker {
            capturing = true;
            continue;
        }
        if capturing && line.trim().starts_with(end_marker_prefix) && line.trim().ends_with("===") {
            break;
        }
        if capturing {
            lines.push(line);
        }
    }

    if lines.is_empty() {
        None
    } else {
        Some(lines.join("\n"))
    }
}
