use crate::config::SshConfig;
use tokio::process::Command;

pub struct SshResult {
    pub success: bool,
    pub output: String,
}

/// Build SSH command with common options including connection multiplexing.
fn ssh_base(config: &SshConfig) -> Command {
    let mut cmd = Command::new("ssh");
    cmd.arg("-o").arg("StrictHostKeyChecking=no")
        .arg("-o").arg("ConnectTimeout=10")
        .arg("-o").arg("BatchMode=yes")
        .arg("-o").arg("ControlMaster=auto")
        .arg("-o").arg(format!("ControlPath=/tmp/ssh-mux-{}@{}:%p", config.user, config.host))
        .arg("-o").arg("ControlPersist=60")
        .arg("-i").arg(&config.key_path)
        .arg(format!("{}@{}", config.user, config.host));
    cmd
}

/// Execute a command on a remote VM via SSH.
pub async fn ssh_command(config: &SshConfig, command: &str) -> SshResult {
    let result = ssh_base(config)
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

/// Fast SSH connectivity check with a short timeout (3s).
pub async fn check_ssh_fast(config: &SshConfig) -> bool {
    let result = ssh_base(config)
        .arg("-o").arg("ConnectTimeout=3")
        .arg("true")
        .output()
        .await;
    matches!(result, Ok(o) if o.status.success())
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
