use crate::config::SshConfig;
use tokio::process::Command;

pub struct SshResult {
    pub success: bool,
    pub output: String,
}

/// Execute a command on a remote VM via SSH.
pub async fn ssh_command(config: &SshConfig, command: &str) -> SshResult {
    let result = Command::new("ssh")
        .arg("-o").arg("StrictHostKeyChecking=no")
        .arg("-o").arg("ConnectTimeout=10")
        .arg("-o").arg("BatchMode=yes")
        .arg("-i").arg(&config.key_path)
        .arg(format!("{}@{}", config.user, config.host))
        .arg(command)
        .output()
        .await;

    match result {
        Ok(output) => {
            if output.status.success() {
                SshResult {
                    success: true,
                    output: String::from_utf8_lossy(&output.stdout).trim().to_string(),
                }
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                SshResult {
                    success: false,
                    output: if stderr.is_empty() { "Command failed".into() } else { stderr },
                }
            }
        }
        Err(e) => SshResult {
            success: false,
            output: format!("SSH execution error: {e}"),
        },
    }
}

/// Check if SSH connection is possible (runs `true`).
pub async fn check_ssh(config: &SshConfig) -> bool {
    ssh_command(config, "true").await.success
}

/// Check if host responds to ping.
pub async fn check_ping(host: &str) -> bool {
    let result = Command::new("ping")
        .arg("-c").arg("1")
        .arg("-W").arg("2")
        .arg(host)
        .output()
        .await;

    matches!(result, Ok(o) if o.status.success())
}
