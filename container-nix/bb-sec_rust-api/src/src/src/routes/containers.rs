use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::error::AppError;
use crate::models::api_response::ContainerInfo;
use crate::models::vm::{validate_container_name, validate_vm_id};
use crate::services::ssh;
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/vms/{vm_id}/containers", get(list_containers))
        .route("/rust/vms/{vm_id}/containers/{name}/start", post(start_container))
        .route("/rust/vms/{vm_id}/containers/{name}/stop", post(stop_container))
        .route("/rust/vms/{vm_id}/containers/{name}/restart", post(restart_container))
}

fn get_ssh_config<'a>(state: &'a crate::AppState, vm_id: &str) -> Result<&'a crate::config::SshConfig, AppError> {
    state
        .config
        .vm_ssh
        .get(vm_id)
        .ok_or_else(|| AppError::not_found(format!("SSH not configured for {vm_id}")))
}

#[utoipa::path(
    get,
    path = "/rust/vms/{vm_id}/containers",
    tag = "containers",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "Container list", body = Vec<ContainerInfo>),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to list containers")
    )
)]
pub async fn list_containers(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }

    let ssh_cfg = get_ssh_config(&state, &vm_id)?;
    let result = ssh::ssh_command(
        ssh_cfg,
        "sudo docker ps -a --format '{{.Names}}|{{.Status}}|{{.Ports}}'",
    )
    .await;

    if !result.success {
        return Err(AppError::internal(format!("Failed to list containers: {}", result.output)));
    }

    let containers: Vec<ContainerInfo> = result
        .output
        .lines()
        .filter(|line| line.contains('|'))
        .map(|line| {
            let parts: Vec<&str> = line.splitn(3, '|').collect();
            ContainerInfo {
                name: parts.first().unwrap_or(&"").to_string(),
                status: parts.get(1).unwrap_or(&"").to_string(),
                ports: parts.get(2).unwrap_or(&"").to_string(),
            }
        })
        .collect();

    Ok(Json(json!({"vm_id": vm_id, "containers": containers})))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/containers/{name}/start",
    tag = "containers",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name")
    ),
    responses(
        (status = 200, description = "Container started", body = Value),
        (status = 500, description = "Failed to start container")
    )
)]
pub async fn start_container(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) || !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid VM ID or container name"));
    }

    let ssh_cfg = get_ssh_config(&state, &vm_id)?;
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {name}")).await;

    if result.success {
        Ok(Json(json!({"status": "ok", "action": "started", "container": name, "vm": vm_id})))
    } else {
        Err(AppError::internal(format!("Failed to start container: {}", result.output)))
    }
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/containers/{name}/stop",
    tag = "containers",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name")
    ),
    responses(
        (status = 200, description = "Container stopped", body = Value),
        (status = 500, description = "Failed to stop container")
    )
)]
pub async fn stop_container(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) || !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid VM ID or container name"));
    }

    let ssh_cfg = get_ssh_config(&state, &vm_id)?;
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {name}")).await;

    if result.success {
        Ok(Json(json!({"status": "ok", "action": "stopped", "container": name, "vm": vm_id})))
    } else {
        Err(AppError::internal(format!("Failed to stop container: {}", result.output)))
    }
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/containers/{name}/restart",
    tag = "containers",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name")
    ),
    responses(
        (status = 200, description = "Container restarted", body = Value),
        (status = 500, description = "Failed to restart container")
    )
)]
pub async fn restart_container(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) || !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid VM ID or container name"));
    }

    let ssh_cfg = get_ssh_config(&state, &vm_id)?;
    let result = ssh::ssh_command(ssh_cfg, &format!("docker restart {name}")).await;

    if result.success {
        Ok(Json(json!({"status": "ok", "action": "restarted", "container": name, "vm": vm_id})))
    } else {
        Err(AppError::internal(format!("Failed to restart container: {}", result.output)))
    }
}
