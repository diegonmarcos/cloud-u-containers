use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::AppError;
use crate::services::oci;
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/wake/trigger", post(trigger_wake))
        .route("/rust/wake/status", get(wake_status))
}

#[utoipa::path(
    post,
    path = "/rust/wake/trigger",
    tag = "wake",
    responses(
        (status = 200, description = "Wake triggered or already running", body = Value),
        (status = 503, description = "OCI not configured")
    )
)]
pub async fn trigger_wake(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let vm = state
        .config
        .vm_instances
        .get(flex_vm_id)
        .ok_or_else(|| AppError::service_unavailable("OCI not configured for flex VM"))?;

    let instance_id = vm.instance_id.clone();

    // Check current state
    let current = oci::get_instance_state(&state.http, &state.config, &instance_id)
        .await
        .unwrap_or_else(|_| "UNKNOWN".into());

    if current == "RUNNING" {
        return Ok(Json(json!({"status": "already_running", "message": "Instance is already running"})));
    }

    if current == "STARTING" {
        return Ok(Json(json!({"status": "starting", "message": "Instance is already starting"})));
    }

    // Check if wake is already in progress
    {
        let wake = state.wake.inner.lock().await;
        if wake.status == "starting" {
            return Ok(Json(json!({"status": "starting", "message": "Wake already in progress"})));
        }
    }

    // Set wake state
    {
        let mut wake = state.wake.inner.lock().await;
        wake.status = "starting".into();
        wake.message = "Sending start command to OCI...".into();
        wake.last_trigger = Some(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs_f64(),
        );
    }

    // Start background poller
    let state_clone = state.clone();
    let instance_id_clone = instance_id.clone();
    tokio::spawn(async move {
        // Send start command
        let result = oci::instance_action(
            &state_clone.http,
            &state_clone.config,
            &instance_id_clone,
            "START",
        )
        .await;

        if let Err(e) = result {
            let mut wake = state_clone.wake.inner.lock().await;
            wake.status = "error".into();
            wake.message = format!("Failed to start: {e}");
            return;
        }

        // Poll for running state (max 5 minutes, every 5 seconds)
        for _ in 0..60 {
            tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

            let current = oci::get_instance_state(
                &state_clone.http,
                &state_clone.config,
                &instance_id_clone,
            )
            .await
            .unwrap_or_else(|_| "UNKNOWN".into());

            let mut wake = state_clone.wake.inner.lock().await;
            wake.message = format!("Instance state: {current}");

            if current == "RUNNING" {
                wake.status = "running".into();
                return;
            }
            if current == "TERMINATED" || current == "TERMINATING" {
                wake.status = "error".into();
                wake.message = format!("Instance in unexpected state: {current}");
                return;
            }
        }

        let mut wake = state_clone.wake.inner.lock().await;
        wake.status = "timeout".into();
        wake.message = "Timeout waiting for instance to start".into();
    });

    Ok(Json(json!({"status": "ok", "message": "Wake command triggered"})))
}

#[utoipa::path(
    get,
    path = "/rust/wake/status",
    tag = "wake",
    responses(
        (status = 200, description = "Current wake and instance status", body = Value)
    )
)]
pub async fn wake_status(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let instance_state = if let Some(vm) = state.config.vm_instances.get(flex_vm_id) {
        oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
            .await
            .unwrap_or_else(|_| "unknown".into())
    } else {
        "not_configured".into()
    };

    let wake = state.wake.inner.lock().await;

    Ok(Json(json!({
        "instance_state": instance_state,
        "wake_status": wake.status,
        "message": wake.message,
        "last_trigger": wake.last_trigger,
    })))
}
