use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::config::VmProvider;
use crate::error::AppError;
use crate::models::vm::validate_container_name;
use crate::services::{oci, ssh};
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/status/flex1", get(status_flex1))
        .route("/rust/status/all", get(status_all))
        .route("/rust/vm/health", get(ondemand_vm_health))
        .route("/rust/vm/start", post(ondemand_vm_start))
        .route("/rust/vm/stop", post(ondemand_vm_stop))
        .route("/rust/vm/reset", post(ondemand_vm_reset))
        .route("/rust/containers/{name}/status", get(ondemand_container_status))
        .route("/rust/containers/{name}/start", post(ondemand_container_start))
        .route("/rust/containers/{name}/stop", post(ondemand_container_stop))
        .route("/rust/containers/{name}/restart", post(ondemand_container_restart))
        .route("/rust/services/{service}/start", post(ondemand_service_start))
        .route("/rust/services/{service}/stop", post(ondemand_service_stop))
}

fn validate_service(service: &str, state: &AppState) -> Result<(), AppError> {
    if state.config.flex_services.contains_key(service) {
        Ok(())
    } else {
        let valid: Vec<String> = state.config.flex_services.keys().cloned().collect();
        Err(AppError::not_found(format!(
            "Unknown service: {service}. Valid: {}",
            valid.join(", ")
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

/// Get the flex VM's provider state.
async fn get_vm_state(state: &AppState) -> Result<String, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let vm = state.config.vm_instances.get(flex_vm_id)
        .ok_or_else(|| AppError::service_unavailable("Flex VM not configured"))?;
    match vm.provider {
        VmProvider::Oci => oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
            .await
            .map_err(|e| AppError::internal(e)),
        VmProvider::Gcp => Ok("UNSUPPORTED".into()),
    }
}

/// Batch-fetch all container states via a single SSH call.
async fn batch_container_statuses(state: &AppState, vm_id: &str) -> Vec<(String, String, String)> {
    let ssh_cfg = match state.config.vm_ssh.get(vm_id) {
        Some(cfg) => cfg,
        None => return vec![],
    };

    let result = ssh::ssh_command(
        ssh_cfg,
        "docker ps -a --format '{{.Names}}|{{.State}}|{{.Ports}}'"
    ).await;

    if !result.success {
        return vec![];
    }

    result.output.lines().filter_map(|line| {
        let parts: Vec<&str> = line.splitn(3, '|').collect();
        if parts.len() >= 2 {
            Some((
                parts[0].to_string(),
                parts[1].to_string(),
                parts.get(2).unwrap_or(&"").to_string(),
            ))
        } else {
            None
        }
    }).collect()
}

/// Compute service status from container states.
fn compute_service_status(containers: &[String], all_statuses: &[(String, String, String)]) -> Value {
    let mut container_details = vec![];
    let mut running = 0;

    for name in containers {
        let (state, ports) = all_statuses.iter()
            .find(|(n, _, _)| n == name)
            .map(|(_, s, p)| (s.clone(), p.clone()))
            .unwrap_or_else(|| ("not_found".into(), String::new()));

        if state == "running" {
            running += 1;
        }
        container_details.push(json!({
            "name": name,
            "state": state,
            "ports": ports,
        }));
    }

    let status = if running == containers.len() {
        "up"
    } else if running == 0 {
        "down"
    } else {
        "partial"
    };

    json!({
        "status": status,
        "containers": container_details,
    })
}

#[utoipa::path(
    get,
    path = "/rust/status/flex1",
    tag = "status",
    responses(
        (status = 200, description = "Flex VM (oci-p-flex_1) status with all services", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn status_flex1(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;

    // Get VM provider state
    let provider_state = get_vm_state(&state).await.unwrap_or_else(|_| "unknown".into());

    // Only attempt SSH/ping if VM appears to be running
    let (ping, ssh_ok, container_data) = if provider_state == "RUNNING" {
        let ssh_cfg = state.config.vm_ssh.get(flex_vm_id);
        let host = ssh_cfg.map(|c| c.host.as_str()).unwrap_or("");

        let ping = ssh::check_ping(host).await;
        let ssh_ok = match ssh_cfg {
            Some(cfg) => ssh::check_ssh(cfg).await,
            None => false,
        };
        let data = batch_container_statuses(&state, flex_vm_id).await;
        (ping, ssh_ok, data)
    } else {
        (false, false, vec![])
    };

    let health = if provider_state == "RUNNING" && ssh_ok {
        "online"
    } else if provider_state == "RUNNING" {
        "degraded"
    } else if provider_state == "STOPPED" {
        "offline"
    } else {
        "unknown"
    };

    // Build per-service status
    let mut services = serde_json::Map::new();
    let mut services_up = 0u32;
    let mut services_down = 0u32;
    let mut services_partial = 0u32;
    let mut containers_running = 0u32;
    let mut containers_total = 0u32;

    for (svc_name, svc) in &state.config.flex_services {
        let svc_status = compute_service_status(&svc.containers, &container_data);
        let status_str = svc_status["status"].as_str().unwrap_or("down");
        match status_str {
            "up" => services_up += 1,
            "partial" => services_partial += 1,
            _ => services_down += 1,
        }
        if let Some(ctrs) = svc_status["containers"].as_array() {
            for c in ctrs {
                containers_total += 1;
                if c["state"].as_str() == Some("running") {
                    containers_running += 1;
                }
            }
        }
        services.insert(svc_name.clone(), svc_status);
    }

    Ok(Json(json!({
        "vm": {
            "id": flex_vm_id,
            "provider_state": provider_state,
            "ssh": ssh_ok,
            "ping": ping,
            "health": health,
        },
        "services": services,
        "summary": {
            "services_up": services_up,
            "services_down": services_down,
            "services_partial": services_partial,
            "containers_running": containers_running,
            "containers_total": containers_total,
        }
    })))
}

#[utoipa::path(
    get,
    path = "/rust/status/all",
    tag = "status",
    responses(
        (status = 200, description = "Status of all 4 VMs with services and containers", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn status_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let mut vms = serde_json::Map::new();
    let mut global_services_up = 0u32;
    let mut global_services_down = 0u32;
    let mut global_services_partial = 0u32;
    let mut global_containers_running = 0u32;
    let mut global_containers_total = 0u32;

    for (vm_id, vm_map) in &state.config.all_vm_services {
        // Get VM instance info
        let vm_instance = state.config.vm_instances.get(vm_id);

        // Get provider state (only for OCI VMs)
        let provider_state = if let Some(vm) = vm_instance {
            match vm.provider {
                VmProvider::Oci => {
                    oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                        .await
                        .unwrap_or_else(|_| "unknown".into())
                }
                VmProvider::Gcp => "N/A".into(),
            }
        } else {
            "not_configured".into()
        };

        // Get SSH config
        let ssh_cfg = state.config.vm_ssh.get(vm_id);
        let host = ssh_cfg.map(|c| c.host.as_str()).unwrap_or("");

        // Check connectivity if VM appears running or for GCP (always try)
        let (ping, ssh_ok, container_data) = if provider_state == "RUNNING" || provider_state == "N/A" {
            let p = ssh::check_ping(host).await;
            let s = match ssh_cfg {
                Some(cfg) => ssh::check_ssh(cfg).await,
                None => false,
            };
            let data = if s {
                batch_container_statuses(&state, vm_id).await
            } else {
                vec![]
            };
            (p, s, data)
        } else {
            (false, false, vec![])
        };

        // Determine overall health
        let health = if (provider_state == "RUNNING" || provider_state == "N/A") && ssh_ok {
            "online"
        } else if provider_state == "RUNNING" || provider_state == "N/A" {
            "degraded"
        } else if provider_state == "STOPPED" {
            "offline"
        } else {
            "unknown"
        };

        // Build per-service status for this VM
        let mut services = serde_json::Map::new();
        let mut vm_services_up = 0u32;
        let mut vm_services_down = 0u32;
        let mut vm_services_partial = 0u32;
        let mut vm_containers_running = 0u32;
        let mut vm_containers_total = 0u32;

        for (svc_name, containers) in &vm_map.services {
            let svc_status = compute_service_status(containers, &container_data);
            let status_str = svc_status["status"].as_str().unwrap_or("down");
            match status_str {
                "up" => vm_services_up += 1,
                "partial" => vm_services_partial += 1,
                _ => vm_services_down += 1,
            }
            if let Some(ctrs) = svc_status["containers"].as_array() {
                for c in ctrs {
                    vm_containers_total += 1;
                    if c["state"].as_str() == Some("running") {
                        vm_containers_running += 1;
                    }
                }
            }
            services.insert(svc_name.clone(), svc_status);
        }

        global_services_up += vm_services_up;
        global_services_down += vm_services_down;
        global_services_partial += vm_services_partial;
        global_containers_running += vm_containers_running;
        global_containers_total += vm_containers_total;

        vms.insert(vm_id.clone(), json!({
            "label": vm_map.label,
            "provider_state": provider_state,
            "ssh": ssh_ok,
            "ping": ping,
            "health": health,
            "services": services,
            "summary": {
                "services_up": vm_services_up,
                "services_down": vm_services_down,
                "services_partial": vm_services_partial,
                "containers_running": vm_containers_running,
                "containers_total": vm_containers_total,
            }
        }));
    }

    Ok(Json(json!({
        "vms": vms,
        "global_summary": {
            "services_up": global_services_up,
            "services_down": global_services_down,
            "services_partial": global_services_partial,
            "containers_running": global_containers_running,
            "containers_total": global_containers_total,
        }
    })))
}

#[utoipa::path(
    get,
    path = "/rust/vm/health",
    tag = "vm",
    responses(
        (status = 200, description = "Flex VM health check", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn ondemand_vm_health(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let provider_state = get_vm_state(&state).await.unwrap_or_else(|_| "unknown".into());

    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id);
    let host = ssh_cfg.map(|c| c.host.as_str()).unwrap_or("");

    let (ping, ssh_ok) = if provider_state == "RUNNING" {
        let p = ssh::check_ping(host).await;
        let s = match ssh_cfg {
            Some(cfg) => ssh::check_ssh(cfg).await,
            None => false,
        };
        (p, s)
    } else {
        (false, false)
    };

    let health = if provider_state == "RUNNING" && ssh_ok {
        "online"
    } else if provider_state == "RUNNING" {
        "degraded"
    } else if provider_state == "STOPPED" {
        "offline"
    } else {
        "unknown"
    };

    Ok(Json(json!({
        "id": flex_vm_id,
        "provider_state": provider_state,
        "ssh": ssh_ok,
        "ping": ping,
        "health": health,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vm/start",
    tag = "vm",
    responses(
        (status = 200, description = "VM started", body = Value),
        (status = 500, description = "Failed to start VM")
    )
)]
pub async fn ondemand_vm_start(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let vm_state = ensure_vm_running(&state).await?;
    Ok(Json(json!({
        "status": "ok",
        "vm_state": vm_state,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vm/stop",
    tag = "vm",
    responses(
        (status = 200, description = "VM stopped gracefully", body = Value),
        (status = 500, description = "Failed to stop VM")
    )
)]
pub async fn ondemand_vm_stop(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;

    // Stop all containers first via SSH (best-effort)
    if let Some(ssh_cfg) = state.config.vm_ssh.get(flex_vm_id) {
        let all_containers: Vec<String> = state.config.flex_services
            .values()
            .flat_map(|svc| svc.containers.clone())
            .collect();
        if !all_containers.is_empty() {
            let containers_str = all_containers.join(" ");
            let _ = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;
        }
    }

    // Stop VM
    let vm = state.config.vm_instances.get(flex_vm_id)
        .ok_or_else(|| AppError::service_unavailable("Flex VM not configured"))?;

    match vm.provider {
        VmProvider::Oci => {
            oci::instance_action(&state.http, &state.config, &vm.instance_id, "STOP")
                .await
                .map_err(|e| AppError::internal(e))?;
        }
        VmProvider::Gcp => {}
    }

    Ok(Json(json!({
        "status": "ok",
        "action": "stop",
        "vm_id": flex_vm_id,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vm/reset",
    tag = "vm",
    responses(
        (status = 200, description = "VM reset/started", body = Value),
        (status = 500, description = "Failed to reset VM")
    )
)]
pub async fn ondemand_vm_reset(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let vm = state.config.vm_instances.get(flex_vm_id)
        .ok_or_else(|| AppError::service_unavailable("Flex VM not configured"))?;

    let current = match vm.provider {
        VmProvider::Oci => oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
            .await
            .map_err(|e| AppError::internal(e))?,
        VmProvider::Gcp => return Err(AppError::bad_request("GCP not supported for reset")),
    };

    let action = if current == "RUNNING" { "SOFTRESET" } else { "START" };
    oci::instance_action(&state.http, &state.config, &vm.instance_id, action)
        .await
        .map_err(|e| AppError::internal(e))?;

    Ok(Json(json!({
        "status": "ok",
        "previous_state": current,
        "action": action,
        "vm_id": flex_vm_id,
    })))
}

#[utoipa::path(
    get,
    path = "/rust/containers/{name}/status",
    tag = "containers",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container status", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Internal error")
    )
)]
pub async fn ondemand_container_status(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }

    let statuses = get_container_statuses(&state, &[name.clone()]).await;
    let status = statuses.into_iter().next().unwrap_or_else(|| json!({"name": name, "status": "unknown"}));

    Ok(Json(status))
}

#[utoipa::path(
    post,
    path = "/rust/containers/{name}/start",
    tag = "containers",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container started", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Failed to start container")
    )
)]
pub async fn ondemand_container_start(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }

    // Auto-start VM if needed
    let vm_state = ensure_vm_running(&state).await?;

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to start container: {}", result.output)));
    }

    let statuses = get_container_statuses(&state, &[name.clone()]).await;

    Ok(Json(json!({
        "status": "ok",
        "vm_state": vm_state,
        "container": statuses.into_iter().next(),
    })))
}

#[utoipa::path(
    post,
    path = "/rust/containers/{name}/stop",
    tag = "containers",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container stopped", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Failed to stop container")
    )
)]
pub async fn ondemand_container_stop(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to stop container: {}", result.output)));
    }

    Ok(Json(json!({
        "status": "ok",
        "container": name,
        "action": "stopped",
    })))
}

#[utoipa::path(
    post,
    path = "/rust/containers/{name}/restart",
    tag = "containers",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container restarted", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Failed to restart container")
    )
)]
pub async fn ondemand_container_restart(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }

    // Auto-start VM if needed
    let vm_state = ensure_vm_running(&state).await?;

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let result = ssh::ssh_command(ssh_cfg, &format!("docker restart {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to restart container: {}", result.output)));
    }

    let statuses = get_container_statuses(&state, &[name.clone()]).await;

    Ok(Json(json!({
        "status": "ok",
        "vm_state": vm_state,
        "container": statuses.into_iter().next(),
    })))
}

#[utoipa::path(
    post,
    path = "/rust/services/{service}/start",
    tag = "services",
    params(("service" = String, Path, description = "Service name (sync, photos, calendar, cache)")),
    responses(
        (status = 200, description = "Service started", body = Value),
        (status = 404, description = "Unknown service"),
        (status = 500, description = "Failed to start service")
    )
)]
pub async fn ondemand_service_start(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    validate_service(&service, &state)?;

    let flex_svc = state.config.flex_services.get(&service)
        .ok_or_else(|| AppError::not_found(format!("Service config not found: {service}")))?;
    let containers = flex_svc.containers.clone();

    // Auto-start VM if needed
    let vm_state = ensure_vm_running(&state).await?;

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let containers_str = containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {containers_str}")).await;

    let statuses = get_container_statuses(&state, &containers).await;

    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "service": service,
        "vm_state": vm_state,
        "containers": statuses,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/services/{service}/stop",
    tag = "services",
    params(("service" = String, Path, description = "Service name (sync, photos, calendar, cache)")),
    responses(
        (status = 200, description = "Service stopped", body = Value),
        (status = 404, description = "Unknown service"),
        (status = 500, description = "Failed to stop service")
    )
)]
pub async fn ondemand_service_stop(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    validate_service(&service, &state)?;

    let flex_svc = state.config.flex_services.get(&service)
        .ok_or_else(|| AppError::not_found(format!("Service config not found: {service}")))?;
    let containers = flex_svc.containers.clone();

    let flex_vm_id = &state.config.flex_vm_id;
    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let containers_str = containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;

    if !result.success {
        return Err(AppError::internal(format!("Failed to stop containers: {}", result.output)));
    }

    Ok(Json(json!({
        "status": "ok",
        "service": service,
        "action": "stopped",
        "containers": containers,
    })))
}
