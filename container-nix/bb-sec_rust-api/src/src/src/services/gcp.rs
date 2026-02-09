use tokio::process::Command;

/// Get GCP instance state via gcloud CLI.
pub async fn get_instance_state(name: &str, zone: &str) -> Result<String, String> {
    let output = Command::new("gcloud")
        .args(["compute", "instances", "describe", name])
        .arg(format!("--zone={zone}"))
        .arg("--format=value(status)")
        .output()
        .await
        .map_err(|e| format!("gcloud exec error: {e}"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_uppercase())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// Perform a GCP instance action (start, stop, reset).
pub async fn instance_action(name: &str, zone: &str, action: &str) -> Result<String, String> {
    let output = Command::new("gcloud")
        .args(["compute", "instances", action, name])
        .arg(format!("--zone={zone}"))
        .arg("--quiet")
        .output()
        .await
        .map_err(|e| format!("gcloud exec error: {e}"))?;

    if output.status.success() {
        Ok(format!("{action} command sent"))
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}
