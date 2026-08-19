//! Canonical SSH helper for all reports.
//!
//! HARD DEADLINE BOUNDS — every SSH call is capped by:
//!   1. `ConnectTimeout=5`           — TCP+auth handshake
//!   2. `ServerAliveInterval=15`     — kernel-level keepalive probe cadence
//!   3. `ServerAliveCountMax=2`      — 2 × 15s = 30s max before dead-conn abort
//!   4. `tokio::time::timeout`       — outer wall-clock fuse per call
//!
//! The combination means a dead VM (e.g. TERMINATED spot instance) returns
//! within ~30s regardless of the user's global ~/.ssh/config keepalive
//! policy. This is the engine-level fix that eliminates the 300s SSH hang
//! burn that previously caused report pipelines to exceed 7 minutes.
//!
//! `ControlMaster=auto` + `ControlPersist=30` amortises subsequent calls to
//! the same host within 30s (SSH channel reuse), so a batch of 20 commands
//! to the same VM costs ~1 TCP handshake + 19 channel open/closes.

use anyhow::Result;
use std::time::Duration;
use tokio::time::timeout;

const SSH_TIMEOUT: Duration = Duration::from_secs(10);

/// Canonical SSH options — applied to every spawn. Fail-fast keepalive
/// bound at 30s overrides any user-level ~/.ssh/config permissive defaults.
pub const SSH_OPTS: &[&str] = &[
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=2",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=/tmp/cloud-reports-mux-%h",
    "-o", "ControlPersist=30",
];

fn build_args<'a>(vm_alias: &'a str, command: &'a str) -> Vec<&'a str> {
    let mut v: Vec<&str> = SSH_OPTS.to_vec();
    v.push(vm_alias);
    v.push(command);
    v
}

/// Execute a command on a remote VM via SSH with ControlMaster muxing.
/// Hard-capped at `timeout_secs` wall-clock (outer) AND 30s dead-conn
/// abort (inner, via ServerAlive keepalive).
///
/// Retries once on failure: since every call to the same VM shares one
/// ControlMaster mux (ControlPath=/tmp/cloud-reports-mux-%h), a single
/// glitch on that master connection (WG jitter, or a CPU-starved 1-vCPU
/// free-tier VM delaying keepalive probes past their nominal window)
/// kills every session multiplexed over it simultaneously — observed as
/// "Broken pipe" / "read from master failed" or a plain non-zero exit
/// with only the host-key TOFU warning on stderr. This is transient
/// connection flakiness, not a logic bug, so a bounded retry is the
/// correct response rather than a deeper investigation per occurrence.
pub async fn ssh_exec(vm_alias: &str, command: &str, timeout_secs: u64) -> Result<String> {
    match ssh_exec_once(vm_alias, command, timeout_secs).await {
        Ok(out) => Ok(out),
        Err(first_err) => {
            tokio::time::sleep(Duration::from_secs(2)).await;
            ssh_exec_once(vm_alias, command, timeout_secs)
                .await
                .map_err(|retry_err| {
                    anyhow::anyhow!(
                        "SSH to {} failed twice — first: {}; retry: {}",
                        vm_alias, first_err, retry_err
                    )
                })
        }
    }
}

async fn ssh_exec_once(vm_alias: &str, command: &str, timeout_secs: u64) -> Result<String> {
    let output = timeout(
        Duration::from_secs(timeout_secs),
        tokio::process::Command::new("ssh")
            .args(build_args(vm_alias, command))
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

/// Execute SSH command returning raw bytes (for binary data like docker export).
/// Retries once — see `ssh_exec`'s doc comment for why (shared ControlMaster
/// mux means one glitch kills every multiplexed session on that VM at once).
pub async fn ssh_exec_raw(vm_alias: &str, command: &str, timeout_secs: u64) -> Result<Vec<u8>> {
    match ssh_exec_raw_once(vm_alias, command, timeout_secs).await {
        Ok(out) => Ok(out),
        Err(first_err) => {
            tokio::time::sleep(Duration::from_secs(2)).await;
            ssh_exec_raw_once(vm_alias, command, timeout_secs)
                .await
                .map_err(|retry_err| {
                    anyhow::anyhow!(
                        "SSH to {} failed twice — first: {}; retry: {}",
                        vm_alias, first_err, retry_err
                    )
                })
        }
    }
}

async fn ssh_exec_raw_once(vm_alias: &str, command: &str, timeout_secs: u64) -> Result<Vec<u8>> {
    let output = timeout(
        Duration::from_secs(timeout_secs),
        tokio::process::Command::new("ssh")
            .args(build_args(vm_alias, command))
            .output(),
    )
    .await??;

    if output.status.success() {
        Ok(output.stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("SSH to {} failed: {}", vm_alias, stderr.trim())
    }
}

/// SSH echo test — verifies SSH auth works. Always returns within ~30s
/// (5s connect + up to 30s keepalive drain + wall-clock fuse).
pub async fn ssh_echo_test(vm_alias: &str) -> bool {
    timeout(
        SSH_TIMEOUT,
        tokio::process::Command::new("ssh")
            .args(build_args(vm_alias, "echo OK"))
            .output(),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).contains("OK"))
    .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_opts_contain_fail_fast_keepalive() {
        // Fire Rule #4: the explicit fail-fast policy is the whole point of
        // centralising SSH options here. This test pins the policy so a
        // future refactor can't accidentally remove the keepalive bound.
        let opts = SSH_OPTS.join(" ");
        assert!(opts.contains("ServerAliveInterval=15"), "missing ServerAliveInterval");
        assert!(opts.contains("ServerAliveCountMax=2"), "missing ServerAliveCountMax");
        assert!(opts.contains("ConnectTimeout=5"), "missing ConnectTimeout");
        assert!(opts.contains("BatchMode=yes"), "missing BatchMode");
        assert!(opts.contains("ControlMaster=auto"), "missing ControlMaster");
    }

    #[test]
    fn build_args_contains_opts_plus_target() {
        let args = build_args("gcp-proxy", "echo OK");
        assert!(args.contains(&"BatchMode=yes"));
        assert!(args.contains(&"gcp-proxy"));
        assert!(args.contains(&"echo OK"));
        assert_eq!(args.last(), Some(&"echo OK"));
    }

    /// End-to-end timeout bound: a dead host must fail within ~35s even if
    /// the TCP never ACKs. Uses 127.0.0.2:22 which is typically unbound
    /// (loopback but no listener). Skipped if that port happens to be up.
    #[tokio::test]
    async fn dead_host_ssh_fails_within_deadline() {
        use std::time::Instant;
        // Only run if we can actually verify dead port (skip in sandboxes).
        if tokio::net::TcpStream::connect("127.0.0.2:22").await.is_ok() {
            eprintln!("skip: 127.0.0.2:22 unexpectedly open");
            return;
        }
        let t0 = Instant::now();
        // Use an IP directly; no ssh_alias resolution happens here.
        let res = timeout(
            Duration::from_secs(40),
            tokio::process::Command::new("ssh")
                .args({
                    let mut v = SSH_OPTS.to_vec();
                    v.push("root@127.0.0.2");
                    v.push("echo OK");
                    v
                })
                .output(),
        )
        .await;
        let elapsed = t0.elapsed();
        assert!(
            elapsed < Duration::from_secs(35),
            "SSH to dead host took {}s; expected <35s (keepalive bound)",
            elapsed.as_secs()
        );
        let _ = res; // the actual exit status doesn't matter — timing does
    }
}
