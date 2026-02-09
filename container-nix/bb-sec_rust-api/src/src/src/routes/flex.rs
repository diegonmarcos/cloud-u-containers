use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::config::VmProvider;
use crate::error::AppError;
use crate::services::{oci, ssh};
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/flex/{service}/wake", post(flex_wake))
        .route("/rust/flex/{service}/sleep", post(flex_sleep))
        .route("/rust/flex/{service}/status", get(flex_service_status))
        .route("/rust/flex/status", get(flex_status_all))
        .route("/rust/flex/wake-all", post(flex_wake_all))
        .route("/rust/flex/sleep-all", post(flex_sleep_all))
}

const VALID_SERVICES: &[&str] = &["sync", "photos", "calendar", "cache"];

fn validate_service(service: &str) -> Result<(), AppError> {
    if VALID_SERVICES.contains(&service) {
        Ok(())
    } else {
        Err(AppError::not_found(format!(
            "Unknown flex service: {service}. Valid: {}",
            VALID_SERVICES.join(", ")
        )))
    }
}

/// Ensure the flex VM is running. Returns the current state.
async fn ensure_vm_running(state: &AppState) -> Result<String, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let vm = state
        .config
        .vm_instances
        .get(flex_vm_id)
        .ok_or_else(|| AppError::service_unavailable("Flex VM not configured"))?;

    match vm.provider {
        VmProvider::Oci => {
            let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                .await
                .map_err(|e| AppError::internal(e))?;

            if current == "RUNNING" {
                return Ok(current);
            }

            if current == "STOPPED" {
                oci::instance_action(&state.http, &state.config, &vm.instance_id, "START")
                    .await
                    .map_err(|e| AppError::internal(e))?;

                // Poll until running (max 5 minutes)
                for _ in 0..60 {
                    tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                    let state_now = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                        .await
                        .unwrap_or_else(|_| "UNKNOWN".into());
                    if state_now == "RUNNING" {
                        // Wait a bit more for SSH to be ready
                        tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                        return Ok("RUNNING".into());
                    }
                }
                return Err(AppError::internal("Timeout waiting for VM to start"));
            }

            Ok(current)
        }
        VmProvider::Gcp => Ok("UNSUPPORTED".into()),
    }
}

/// Get container statuses on the flex VM.
async fn get_container_statuses(state: &AppState, containers: &[String]) -> Vec<Value> {
    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = match state.config.vm_ssh.get(flex_vm_id) {
        Some(cfg) => cfg,
        None => return vec![],
    };

    let mut statuses = vec![];
    for name in containers {
        let result = ssh::ssh_command(
            ssh_cfg,
            &format!("docker inspect --format '{{{{.State.Status}}}}' {name} 2>/dev/null || echo 'not_found'"),
        )
        .await;

        statuses.push(json!({
            "name": name,
            "status": if result.success { result.output } else { "unknown".into() }
        }));
    }
    statuses
}

#[utoipa::path(
    post,
    path = "/rust/flex/{service}/wake",
    tag = "flex",
    params(("service" = String, Path, description = "Service name (sync, photos, calendar, cache)")),
    responses(
        (status = 200, description = "Service woken", body = Value),
        (status = 404, description = "Unknown service"),
        (status = 500, description = "Failed to wake service")
    )
)]
pub async fn flex_wake(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    validate_service(&service)?;

    let flex_svc = state
        .config
        .flex_services
        .get(&service)
        .ok_or_else(|| AppError::not_found(format!("Service config not found: {service}")))?;

    // Ensure VM is running
    let vm_state = ensure_vm_running(&state).await?;

    // Start containers
    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state
        .config
        .vm_ssh
        .get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let containers_str = flex_svc.containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {containers_str}")).await;

    if !result.success {
        return Err(AppError::internal(format!("Failed to start containers: {}", result.output)));
    }

    let statuses = get_container_statuses(&state, &flex_svc.containers).await;

    Ok(Json(json!({
        "status": "ok",
        "service": service,
        "vm_state": vm_state,
        "containers": statuses,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/flex/{service}/sleep",
    tag = "flex",
    params(("service" = String, Path, description = "Service name (sync, photos, calendar, cache)")),
    responses(
        (status = 200, description = "Service stopped", body = Value),
        (status = 404, description = "Unknown service"),
        (status = 500, description = "Failed to stop service")
    )
)]
pub async fn flex_sleep(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    validate_service(&service)?;

    let flex_svc = state
        .config
        .flex_services
        .get(&service)
        .ok_or_else(|| AppError::not_found(format!("Service config not found: {service}")))?;

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state
        .config
        .vm_ssh
        .get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let containers_str = flex_svc.containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;

    if !result.success {
        return Err(AppError::internal(format!("Failed to stop containers: {}", result.output)));
    }

    Ok(Json(json!({
        "status": "ok",
        "service": service,
        "action": "stopped",
        "containers": flex_svc.containers,
    })))
}

#[utoipa::path(
    get,
    path = "/rust/flex/{service}/status",
    tag = "flex",
    params(("service" = String, Path, description = "Service name (sync, photos, calendar, cache)")),
    responses(
        (status = 200, description = "Service status", body = Value),
        (status = 404, description = "Unknown service")
    )
)]
pub async fn flex_service_status(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    validate_service(&service)?;

    let flex_svc = state
        .config
        .flex_services
        .get(&service)
        .ok_or_else(|| AppError::not_found(format!("Service config not found: {service}")))?;

    let statuses = get_container_statuses(&state, &flex_svc.containers).await;

    Ok(Json(json!({
        "service": service,
        "containers": statuses,
    })))
}

#[utoipa::path(
    get,
    path = "/rust/flex/status",
    tag = "flex",
    responses(
        (status = 200, description = "All flex services status", body = Value)
    )
)]
pub async fn flex_status_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    // Get VM state
    let flex_vm_id = &state.config.flex_vm_id;
    let vm_state = if let Some(vm) = state.config.vm_instances.get(flex_vm_id) {
        oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
            .await
            .unwrap_or_else(|_| "unknown".into())
    } else {
        "not_configured".into()
    };

    let mut services = json!({});
    for (name, svc) in &state.config.flex_services {
        let statuses = get_container_statuses(&state, &svc.containers).await;
        services[name] = json!({"containers": statuses});
    }

    Ok(Json(json!({
        "vm_id": flex_vm_id,
        "vm_state": vm_state,
        "services": services,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/flex/wake-all",
    tag = "flex",
    responses(
        (status = 200, description = "All flex services woken", body = Value),
        (status = 500, description = "Failed to wake services")
    )
)]
pub async fn flex_wake_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let vm_state = ensure_vm_running(&state).await?;

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state
        .config
        .vm_ssh
        .get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    // Collect all containers
    let all_containers: Vec<String> = state
        .config
        .flex_services
        .values()
        .flat_map(|svc| svc.containers.clone())
        .collect();

    let containers_str = all_containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {containers_str}")).await;

    let statuses = get_container_statuses(&state, &all_containers).await;

    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "vm_state": vm_state,
        "containers": statuses,
        "message": if result.success { "All containers started".to_string() } else { result.output },
    })))
}

#[utoipa::path(
    post,
    path = "/rust/flex/sleep-all",
    tag = "flex",
    responses(
        (status = 200, description = "All flex services stopped + VM", body = Value),
        (status = 500, description = "Failed to stop services")
    )
)]
pub async fn flex_sleep_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state
        .config
        .vm_ssh
        .get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    // Stop all containers
    let all_containers: Vec<String> = state
        .config
        .flex_services
        .values()
        .flat_map(|svc| svc.containers.clone())
        .collect();

    let containers_str = all_containers.join(" ");
    let _ = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;

    // Stop the VM
    let mut vm_stopped = false;
    if let Some(vm) = state.config.vm_instances.get(flex_vm_id) {
        match vm.provider {
            VmProvider::Oci => {
                if oci::instance_action(&state.http, &state.config, &vm.instance_id, "STOP")
                    .await
                    .is_ok()
                {
                    vm_stopped = true;
                }
            }
            VmProvider::Gcp => {}
        }
    }

    Ok(Json(json!({
        "status": "ok",
        "containers_stopped": all_containers,
        "vm_stopped": vm_stopped,
    })))
}
