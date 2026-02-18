use axum::extract::State;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::error::AppError;
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/cloud/oci/instances", get(oci_instances))
        .route("/api/cloud/gcp/instances", get(gcp_instances))
        .route("/api/cloud/oci/resources", get(oci_resources))
        .route("/api/cloud/gcp/resources", get(gcp_resources))
        .route("/api/cloud/oci/costs", get(oci_costs))
        .route("/api/cloud/gcp/costs", get(gcp_costs))
        .route("/api/cloud/summary", get(cloud_summary))
}

#[utoipa::path(
    get,
    path = "/api/cloud/oci/instances",
    tag = "Cloud",
    responses(
        (status = 200, description = "List all OCI compute instances"),
        (status = 500, description = "OCI API error"),
    )
)]
pub async fn oci_instances(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let data = crate::services::oci::list_instances(&state.http, &state.config)
        .await
        .map_err(AppError::internal)?;
    Ok(Json(data))
}

#[utoipa::path(
    get,
    path = "/api/cloud/gcp/instances",
    tag = "Cloud",
    responses(
        (status = 200, description = "List all GCP compute instances"),
        (status = 500, description = "GCP API error"),
    )
)]
pub async fn gcp_instances(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let sa = crate::services::gcp::parse_service_account(&state.config.gcp_service_account_file)
        .map_err(AppError::internal)?;
    let project = if state.config.gcp_project_id.is_empty() {
        &sa.project_id
    } else {
        &state.config.gcp_project_id
    };

    let data = crate::services::gcp::list_instances(
        &state.http, &sa, &state.gcp_token_cache, project,
    )
    .await
    .map_err(AppError::internal)?;
    Ok(Json(data))
}

#[utoipa::path(
    get,
    path = "/api/cloud/oci/resources",
    tag = "Cloud",
    responses(
        (status = 200, description = "List OCI networking and storage resources"),
        (status = 500, description = "OCI API error"),
    )
)]
pub async fn oci_resources(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let data = crate::services::oci::list_resources(&state.http, &state.config)
        .await
        .map_err(AppError::internal)?;
    Ok(Json(data))
}

#[utoipa::path(
    get,
    path = "/api/cloud/gcp/resources",
    tag = "Cloud",
    responses(
        (status = 200, description = "List GCP disks, networks, and firewalls"),
        (status = 500, description = "GCP API error"),
    )
)]
pub async fn gcp_resources(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let sa = crate::services::gcp::parse_service_account(&state.config.gcp_service_account_file)
        .map_err(AppError::internal)?;
    let project = if state.config.gcp_project_id.is_empty() {
        &sa.project_id
    } else {
        &state.config.gcp_project_id
    };

    let data = crate::services::gcp::list_resources(
        &state.http, &sa, &state.gcp_token_cache, project,
    )
    .await
    .map_err(AppError::internal)?;
    Ok(Json(data))
}

#[utoipa::path(
    get,
    path = "/api/cloud/oci/costs",
    tag = "Cloud",
    responses(
        (status = 200, description = "OCI usage costs for the last 30 days"),
        (status = 500, description = "OCI Usage API error"),
    )
)]
pub async fn oci_costs(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let data = crate::services::oci::get_usage_costs(&state.http, &state.config)
        .await
        .map_err(AppError::internal)?;
    Ok(Json(data))
}

#[utoipa::path(
    get,
    path = "/api/cloud/gcp/costs",
    tag = "Cloud",
    responses(
        (status = 200, description = "GCP billing info"),
        (status = 500, description = "GCP Billing API error"),
    )
)]
pub async fn gcp_costs(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let sa = crate::services::gcp::parse_service_account(&state.config.gcp_service_account_file)
        .map_err(AppError::internal)?;
    let project = if state.config.gcp_project_id.is_empty() {
        &sa.project_id
    } else {
        &state.config.gcp_project_id
    };

    let data = crate::services::gcp::get_billing_info(
        &state.http, &sa, &state.gcp_token_cache, project,
    )
    .await
    .map_err(AppError::internal)?;
    Ok(Json(data))
}

#[utoipa::path(
    get,
    path = "/api/cloud/summary",
    tag = "Cloud",
    responses(
        (status = 200, description = "Combined cloud summary from all 6 endpoints"),
    )
)]
pub async fn cloud_summary(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let sa = crate::services::gcp::parse_service_account(&state.config.gcp_service_account_file)
        .map_err(AppError::internal)?;
    let project = if state.config.gcp_project_id.is_empty() {
        sa.project_id.clone()
    } else {
        state.config.gcp_project_id.clone()
    };

    let start = std::time::Instant::now();

    let (oci_inst, gcp_inst, oci_res, gcp_res, oci_cost, gcp_cost) = tokio::join!(
        crate::services::oci::list_instances(&state.http, &state.config),
        crate::services::gcp::list_instances(&state.http, &sa, &state.gcp_token_cache, &project),
        crate::services::oci::list_resources(&state.http, &state.config),
        crate::services::gcp::list_resources(&state.http, &sa, &state.gcp_token_cache, &project),
        crate::services::oci::get_usage_costs(&state.http, &state.config),
        crate::services::gcp::get_billing_info(&state.http, &sa, &state.gcp_token_cache, &project),
    );

    let elapsed = start.elapsed().as_millis() as u64;

    Ok(Json(json!({
        "oci": {
            "instances": oci_inst.unwrap_or_else(|e| json!({"error": e})),
            "resources": oci_res.unwrap_or_else(|e| json!({"error": e})),
            "costs": oci_cost.unwrap_or_else(|e| json!({"error": e})),
        },
        "gcp": {
            "instances": gcp_inst.unwrap_or_else(|e| json!({"error": e})),
            "resources": gcp_res.unwrap_or_else(|e| json!({"error": e})),
            "costs": gcp_cost.unwrap_or_else(|e| json!({"error": e})),
        },
        "total_time_ms": elapsed,
    })))
}
