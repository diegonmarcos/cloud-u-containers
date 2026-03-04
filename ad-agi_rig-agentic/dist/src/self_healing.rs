use crate::config::AppConfig;
use crate::kg::KgClient;
use reqwest::Client;
use serde::Deserialize;
use std::sync::Arc;
use tracing::{error, info, warn};

pub struct SelfHealingLoop {
    kg: Arc<KgClient>,
    config: Arc<AppConfig>,
    http: Client,
}

#[derive(Deserialize)]
struct DockerContainer {
    #[serde(rename = "Names")]
    names: String,
    #[serde(rename = "State")]
    state: String,
    #[serde(rename = "Status")]
    status: String,
}

impl SelfHealingLoop {
    pub fn new(kg: Arc<KgClient>, config: Arc<AppConfig>) -> Self {
        Self {
            kg,
            config,
            http: Client::new(),
        }
    }

    pub async fn run_cycle(&self) -> Result<(), String> {
        info!("Starting self-healing cycle");

        // 1. Check local Docker containers (oci-apps)
        let unhealthy = self.check_local_containers().await?;

        // 2. Auto-restart unhealthy containers
        for container in &unhealthy {
            warn!(container = %container, "Unhealthy container detected, restarting");

            let restarted = self.restart_local_container(container).await;
            let result = if restarted.is_ok() { "success" } else { "failure" };

            self.kg.audit_log(
                "self_healing",
                "restart_container",
                Some(&format!("docker restart {container}")),
                "low",
                result,
                Some(&format!("Auto-restart unhealthy container: {container}")),
            ).await.ok();

            if restarted.is_ok() {
                info!(container = %container, "Container restarted successfully");
            } else {
                error!(container = %container, error = ?restarted.err(), "Failed to restart container");
            }
        }

        // 3. Update KG with current container statuses
        self.sync_container_status().await?;

        // 4. Check SurrealDB connectivity (self-check)
        match self.kg.count_table("vm").await {
            Ok(count) => info!(vm_count = count, "KG connectivity OK"),
            Err(e) => {
                error!(error = %e, "KG connectivity FAILED");
                self.kg.audit_log(
                    "self_healing",
                    "health_check",
                    None,
                    "high",
                    "failure",
                    Some("SurrealDB connectivity lost"),
                ).await.ok();
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
                    // Don't restart ourselves
                    if name != "rig" {
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

    async fn sync_container_status(&self) -> Result<(), String> {
        let output = tokio::process::Command::new("docker")
            .args(["ps", "-a", "--format", "{{.Names}}\t{{.State}}"])
            .output()
            .await
            .map_err(|e| format!("docker ps failed: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout);

        for line in stdout.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 2 {
                let name = parts[0];
                let state = parts[1]; // running, exited, restarting, etc.
                let status = match state {
                    "running" => "healthy",
                    "exited" => "down",
                    "restarting" => "degraded",
                    _ => "unknown",
                };
                // Best effort update - service name may not match container name
                self.kg.update_service_status(name, status).await.ok();
            }
        }

        Ok(())
    }
}
