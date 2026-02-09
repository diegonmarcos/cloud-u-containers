use axum::{
    extract::{Path, State},
    routing::get,
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::error::AppError;
use crate::models::vm::validate_vm_id;
use crate::services::ssh;
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new().route("/rust/vms/{vm_id}/status", get(vm_status))
}

#[utoipa::path(
    get,
    path = "/rust/vms/{vm_id}/status",
    tag = "vmStatus",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM status", body = Value),
        (status = 404, description = "Unknown VM")
    )
)]
pub async fn vm_status(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }

    let ssh_cfg = state
        .config
        .vm_ssh
        .get(&vm_id)
        .ok_or_else(|| AppError::not_found(format!("Unknown VM: {vm_id}")))?;

    let ssh_ok = ssh::check_ssh(ssh_cfg).await;
    let ping_ok = if ssh_ok {
        true
    } else {
        ssh::check_ping(&ssh_cfg.host).await
    };

    let (status, label) = if ssh_ok {
        ("online", "ONLINE")
    } else if ping_ok {
        ("no_ssh", "NO SSH")
    } else {
        ("offline", "OFFLINE")
    };

    Ok(Json(json!({
        "vm_id": vm_id,
        "status": status,
        "label": label,
        "ping": ping_ok,
        "ssh": ssh_ok,
    })))
}
