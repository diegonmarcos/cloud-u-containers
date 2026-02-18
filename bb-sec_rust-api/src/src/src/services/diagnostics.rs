use serde_json::{json, Value};
use std::time::Instant;
use tokio::process::Command;

use crate::config::SshConfig;
use crate::services::ssh;

/// Result of a single diagnostic check.
pub struct CheckResult {
    pub name: String,
    pub success: bool,
    pub time_ms: u64,
    pub data: Value,
}

impl CheckResult {
    pub fn ok(name: &str, time_ms: u64, data: Value) -> Self {
        Self {
            name: name.to_string(),
            success: true,
            time_ms,
            data,
        }
    }

    pub fn fail(name: &str, time_ms: u64, error: &str) -> Self {
        Self {
            name: name.to_string(),
            success: false,
            time_ms,
            data: json!({ "error": error }),
        }
    }

    pub fn fail_with_data(name: &str, time_ms: u64, data: Value) -> Self {
        Self {
            name: name.to_string(),
            success: false,
            time_ms,
            data,
        }
    }
}

/// Ping a host and parse average latency from the rtt summary line.
pub async fn ping_with_latency(host: &str) -> CheckResult {
    let start = Instant::now();
    let result = Command::new("ping")
        .arg("-c").arg("3")
        .arg("-W").arg("2")
        .arg(host)
        .output()
        .await;

    let elapsed = start.elapsed().as_millis() as u64;

    match result {
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let latency = parse_ping_latency(&stdout);
            CheckResult::ok("wireguard_ping", elapsed, json!({
                "host": host,
                "latency_avg_ms": latency,
                "packets_sent": 3,
            }))
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            CheckResult::fail("wireguard_ping", elapsed, &format!("ping failed: {stderr}"))
        }
        Err(e) => CheckResult::fail("wireguard_ping", elapsed, &format!("ping error: {e}")),
    }
}

/// Parse average latency from ping output (rtt min/avg/max/mdev line).
fn parse_ping_latency(output: &str) -> Option<f64> {
    for line in output.lines() {
        // Linux: rtt min/avg/max/mdev = 0.123/0.456/0.789/0.012 ms
        if line.contains("min/avg/max") {
            if let Some(values) = line.split('=').nth(1) {
                let parts: Vec<&str> = values.trim().split('/').collect();
                if parts.len() >= 2 {
                    return parts[1].trim().parse().ok();
                }
            }
        }
    }
    None
}

/// Timed SSH connectivity check.
pub async fn timed_ssh_check(config: &SshConfig) -> CheckResult {
    let start = Instant::now();
    let ok = ssh::check_ssh(config).await;
    let elapsed = start.elapsed().as_millis() as u64;

    if ok {
        CheckResult::ok("ssh_connectivity", elapsed, json!({
            "host": config.host,
            "user": config.user,
        }))
    } else {
        CheckResult::fail("ssh_connectivity", elapsed, &format!(
            "SSH unreachable: {}@{}", config.user, config.host
        ))
    }
}

/// Execute an SSH command with timing and apply a parse function to the output.
pub async fn timed_ssh_command<F>(
    name: &str,
    config: &SshConfig,
    command: &str,
    parse_fn: F,
) -> CheckResult
where
    F: FnOnce(&str) -> (bool, Value),
{
    let start = Instant::now();
    let result = ssh::ssh_command(config, command).await;
    let elapsed = start.elapsed().as_millis() as u64;

    if result.success {
        let (ok, data) = parse_fn(&result.output);
        if ok {
            CheckResult::ok(name, elapsed, data)
        } else {
            CheckResult::fail_with_data(name, elapsed, data)
        }
    } else {
        CheckResult::fail(name, elapsed, &result.output)
    }
}

/// Async TCP connect test with timeout.
pub async fn tcp_connect_check(host: &str, port: u16, timeout_secs: u64) -> (bool, u64) {
    let start = Instant::now();
    let addr = format!("{host}:{port}");
    let timeout = std::time::Duration::from_secs(timeout_secs);

    let ok = tokio::time::timeout(timeout, tokio::net::TcpStream::connect(&addr))
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false);

    let elapsed = start.elapsed().as_millis() as u64;
    (ok, elapsed)
}
