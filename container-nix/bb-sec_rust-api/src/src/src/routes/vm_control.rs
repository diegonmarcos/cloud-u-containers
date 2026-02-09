use axum::{
    extract::{Path, State},
    routing::post,
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::config::VmProvider;
use crate::error::AppError;
use crate::models::vm::validate_vm_id;
use crate::services::{gcp, oci};
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/vms/{vm_id}/start", post(start_vm))
        .route("/rust/vms/{vm_id}/stop", post(stop_vm))
        .route("/rust/vms/{vm_id}/reset", post(reset_vm))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/start",
    tag = "vmControl",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM started", body = Value),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to start VM")
    )
)]
pub async fn start_vm(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }

    // OCI VMs
    if let Some(vm) = state.config.vm_instances.get(&vm_id) {
        match vm.provider {
            VmProvider::Oci => {
                let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                    .await
                    .unwrap_or_else(|_| "UNKNOWN".into());

                if current == "RUNNING" {
                    return Ok(Json(json!({"status": "already_running", "state": current})));
                }

                match oci::instance_action(&state.http, &state.config, &vm.instance_id, "START").await {
                    Ok(msg) => Ok(Json(json!({"status": "ok", "action": "started", "message": msg}))),
                    Err(e) => Err(AppError::internal(e)),
                }
            }
            VmProvider::Gcp => {
                if let Some(gcp_vm) = state.config.gcp_vms.get(&vm_id) {
                    let current = gcp::get_instance_state(&gcp_vm.name, &gcp_vm.zone)
                        .await
                        .unwrap_or_else(|_| "UNKNOWN".into());

                    if current == "RUNNING" {
                        return Ok(Json(json!({"status": "already_running", "state": current})));
                    }

                    match gcp::instance_action(&gcp_vm.name, &gcp_vm.zone, "start").await {
                        Ok(msg) => Ok(Json(json!({"status": "ok", "action": "started", "message": msg}))),
                        Err(e) => Err(AppError::internal(e)),
                    }
                } else {
                    Err(AppError::not_found(format!("GCP config not found for {vm_id}")))
                }
            }
        }
    } else if let Some(gcp_vm) = state.config.gcp_vms.get(&vm_id) {
        // GCP-only VMs (no OCI instance ID)
        let current = gcp::get_instance_state(&gcp_vm.name, &gcp_vm.zone)
            .await
            .unwrap_or_else(|_| "UNKNOWN".into());

        if current == "RUNNING" {
            return Ok(Json(json!({"status": "already_running", "state": current})));
        }

        match gcp::instance_action(&gcp_vm.name, &gcp_vm.zone, "start").await {
            Ok(msg) => Ok(Json(json!({"status": "ok", "action": "started", "message": msg}))),
            Err(e) => Err(AppError::internal(e)),
        }
    } else {
        Err(AppError::not_found(format!("Unknown VM: {vm_id}")))
    }
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/stop",
    tag = "vmControl",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM stopped", body = Value),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to stop VM")
    )
)]
pub async fn stop_vm(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }

    if let Some(vm) = state.config.vm_instances.get(&vm_id) {
        match vm.provider {
            VmProvider::Oci => {
                let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                    .await
                    .unwrap_or_else(|_| "UNKNOWN".into());

                if current == "STOPPED" {
                    return Ok(Json(json!({"status": "already_stopped", "state": current})));
                }

                match oci::instance_action(&state.http, &state.config, &vm.instance_id, "STOP").await {
                    Ok(msg) => Ok(Json(json!({"status": "ok", "action": "stopped", "message": msg}))),
                    Err(e) => Err(AppError::internal(e)),
                }
            }
            VmProvider::Gcp => {
                if let Some(gcp_vm) = state.config.gcp_vms.get(&vm_id) {
                    let current = gcp::get_instance_state(&gcp_vm.name, &gcp_vm.zone)
                        .await
                        .unwrap_or_else(|_| "UNKNOWN".into());

                    if current == "STOPPED" || current == "TERMINATED" {
                        return Ok(Json(json!({"status": "already_stopped", "state": current})));
                    }

                    match gcp::instance_action(&gcp_vm.name, &gcp_vm.zone, "stop").await {
                        Ok(msg) => Ok(Json(json!({"status": "ok", "action": "stopped", "message": msg}))),
                        Err(e) => Err(AppError::internal(e)),
                    }
                } else {
                    Err(AppError::not_found(format!("GCP config not found for {vm_id}")))
                }
            }
        }
    } else if let Some(gcp_vm) = state.config.gcp_vms.get(&vm_id) {
        let current = gcp::get_instance_state(&gcp_vm.name, &gcp_vm.zone)
            .await
            .unwrap_or_else(|_| "UNKNOWN".into());

        if current == "STOPPED" || current == "TERMINATED" {
            return Ok(Json(json!({"status": "already_stopped", "state": current})));
        }

        match gcp::instance_action(&gcp_vm.name, &gcp_vm.zone, "stop").await {
            Ok(msg) => Ok(Json(json!({"status": "ok", "action": "stopped", "message": msg}))),
            Err(e) => Err(AppError::internal(e)),
        }
    } else {
        Err(AppError::not_found(format!("Unknown VM: {vm_id}")))
    }
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/reset",
    tag = "vmControl",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM reset/rebooted", body = Value),
        (status = 400, description = "Cannot reset in current state"),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to reset VM")
    )
)]
pub async fn reset_vm(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }

    if let Some(vm) = state.config.vm_instances.get(&vm_id) {
        match vm.provider {
            VmProvider::Oci => {
                let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                    .await
                    .unwrap_or_else(|_| "UNKNOWN".into());

                let (action, label) = match current.as_str() {
                    "STOPPED" => ("START", "started"),
                    "RUNNING" => ("SOFTRESET", "rebooted"),
                    _ => return Err(AppError::bad_request(format!("Cannot reset VM in state: {current}"))),
                };

                match oci::instance_action(&state.http, &state.config, &vm.instance_id, action).await {
                    Ok(msg) => Ok(Json(json!({"status": "ok", "action": label, "message": msg}))),
                    Err(e) => Err(AppError::internal(e)),
                }
            }
            VmProvider::Gcp => {
                if let Some(gcp_vm) = state.config.gcp_vms.get(&vm_id) {
                    let current = gcp::get_instance_state(&gcp_vm.name, &gcp_vm.zone)
                        .await
                        .unwrap_or_else(|_| "UNKNOWN".into());

                    let (action, label) = match current.as_str() {
                        "STOPPED" | "TERMINATED" => ("start", "started"),
                        "RUNNING" => ("reset", "rebooted"),
                        _ => return Err(AppError::bad_request(format!("Cannot reset VM in state: {current}"))),
                    };

                    match gcp::instance_action(&gcp_vm.name, &gcp_vm.zone, action).await {
                        Ok(msg) => Ok(Json(json!({"status": "ok", "action": label, "message": msg}))),
                        Err(e) => Err(AppError::internal(e)),
                    }
                } else {
                    Err(AppError::not_found(format!("GCP config not found for {vm_id}")))
                }
            }
        }
    } else if let Some(gcp_vm) = state.config.gcp_vms.get(&vm_id) {
        let current = gcp::get_instance_state(&gcp_vm.name, &gcp_vm.zone)
            .await
            .unwrap_or_else(|_| "UNKNOWN".into());

        let (action, label) = match current.as_str() {
            "STOPPED" | "TERMINATED" => ("start", "started"),
            "RUNNING" => ("reset", "rebooted"),
            _ => return Err(AppError::bad_request(format!("Cannot reset VM in state: {current}"))),
        };

        match gcp::instance_action(&gcp_vm.name, &gcp_vm.zone, action).await {
            Ok(msg) => Ok(Json(json!({"status": "ok", "action": label, "message": msg}))),
            Err(e) => Err(AppError::internal(e)),
        }
    } else {
        Err(AppError::not_found(format!("Unknown VM: {vm_id}")))
    }
}
