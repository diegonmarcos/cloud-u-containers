use crate::config::AppConfig;
use std::sync::Arc;
use tracing::{error, info, warn};

pub struct SelfHealingLoop {
    _config: Arc<AppConfig>,
}

impl SelfHealingLoop {
    pub fn new(config: Arc<AppConfig>) -> Self {
        Self { _config: config }
    }

    pub async fn run_cycle(&self) -> Result<(), String> {
        info!("Starting self-healing cycle");

        // Check local Docker containers (oci-apps)
        let unhealthy = self.check_local_containers().await?;

        // Auto-restart unhealthy containers
        for container in &unhealthy {
            warn!(container = %container, "Unhealthy container detected, restarting");

            match self.restart_local_container(container).await {
                Ok(()) => info!(container = %container, "Container restarted successfully"),
                Err(e) => error!(container = %container, error = %e, "Failed to restart container"),
            }
        }

        info!("Self-healing cycle complete");
        Ok(())
    }

    async fn check_local_containers(&self) -> Result<Vec<String>, String> {
        let output = tokio::process::Command::new("docker")
            .args(["ps", "--format", "{{.Names}}\t{{.State}}\t{{.Status}}"])
            .output()
            .await
            .map_err(|e| format!("docker ps failed: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut unhealthy = Vec::new();

        for line in stdout.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 2 {
                let name = parts[0];
                let state = parts[1];
                let status = parts.get(2).unwrap_or(&"");

                if state == "restarting" || status.contains("unhealthy") {
                    // Don't restart any rig-agentic instance
                    if !name.starts_with("rig-agentic") {
                        unhealthy.push(name.to_string());
                    }
                }
            }
        }

        Ok(unhealthy)
    }

    async fn restart_local_container(&self, name: &str) -> Result<(), String> {
        let output = tokio::process::Command::new("docker")
            .args(["restart", name])
            .output()
            .await
            .map_err(|e| format!("docker restart failed: {e}"))?;

        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).to_string())
        }
    }
}
