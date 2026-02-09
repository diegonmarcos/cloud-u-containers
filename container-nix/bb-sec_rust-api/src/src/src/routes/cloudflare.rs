use axum::{
    extract::{Path, State},
    routing::{delete, get, post, put},
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::error::AppError;
use crate::models::api_response::{CachePurgeRequest, DnsRecordCreate, FirewallRule};
use crate::services::cloudflare::CfClient;
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/cf/dns", get(list_dns).post(create_dns))
        .route("/rust/cf/dns/{id}", put(update_dns).delete(delete_dns))
        .route("/rust/cf/cache/purge", post(purge_cache))
        .route("/rust/cf/zone", get(zone_info))
        .route("/rust/cf/firewall", get(list_firewall).post(create_firewall))
        .route("/rust/cf/analytics", get(analytics))
}

fn cf_client(state: &AppState) -> Result<CfClient<'_>, AppError> {
    if state.config.cf_api_token.is_empty() || state.config.cf_zone_id.is_empty() {
        return Err(AppError::service_unavailable("Cloudflare not configured"));
    }
    Ok(CfClient::new(
        &state.http,
        &state.config.cf_api_token,
        &state.config.cf_zone_id,
    ))
}

#[utoipa::path(
    get,
    path = "/rust/cf/dns",
    tag = "cloudflare",
    responses(
        (status = 200, description = "DNS record list", body = Vec<crate::models::api_response::DnsRecord>),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn list_dns(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let records = client.list_dns().await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "records": records, "count": records.len()})))
}

#[utoipa::path(
    post,
    path = "/rust/cf/dns",
    tag = "cloudflare",
    request_body = DnsRecordCreate,
    responses(
        (status = 200, description = "DNS record created", body = crate::models::api_response::DnsRecord),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn create_dns(
    State(state): State<Arc<AppState>>,
    Json(record): Json<DnsRecordCreate>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let created = client.create_dns(&record).await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "record": created})))
}

#[utoipa::path(
    put,
    path = "/rust/cf/dns/{id}",
    tag = "cloudflare",
    params(("id" = String, Path, description = "DNS record ID")),
    request_body = DnsRecordCreate,
    responses(
        (status = 200, description = "DNS record updated", body = crate::models::api_response::DnsRecord),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn update_dns(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(record): Json<DnsRecordCreate>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let updated = client.update_dns(&id, &record).await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "record": updated})))
}

#[utoipa::path(
    delete,
    path = "/rust/cf/dns/{id}",
    tag = "cloudflare",
    params(("id" = String, Path, description = "DNS record ID")),
    responses(
        (status = 200, description = "DNS record deleted"),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn delete_dns(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    client.delete_dns(&id).await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "deleted": id})))
}

#[utoipa::path(
    post,
    path = "/rust/cf/cache/purge",
    tag = "cloudflare",
    request_body = CachePurgeRequest,
    responses(
        (status = 200, description = "Cache purged"),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn purge_cache(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CachePurgeRequest>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    client.purge_cache(&req).await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "message": "Cache purged"})))
}

#[utoipa::path(
    get,
    path = "/rust/cf/zone",
    tag = "cloudflare",
    responses(
        (status = 200, description = "Zone details", body = Value),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn zone_info(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let info = client.zone_info().await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "zone": info})))
}

#[utoipa::path(
    get,
    path = "/rust/cf/firewall",
    tag = "cloudflare",
    responses(
        (status = 200, description = "Firewall rules", body = Vec<FirewallRule>),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn list_firewall(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let rules = client.list_firewall().await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "rules": rules})))
}

#[utoipa::path(
    post,
    path = "/rust/cf/firewall",
    tag = "cloudflare",
    request_body = FirewallRule,
    responses(
        (status = 200, description = "Firewall rule created", body = Value),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn create_firewall(
    State(state): State<Arc<AppState>>,
    Json(rule): Json<FirewallRule>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let result = client.create_firewall(&rule).await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "result": result})))
}

#[utoipa::path(
    get,
    path = "/rust/cf/analytics",
    tag = "cloudflare",
    responses(
        (status = 200, description = "Zone analytics", body = Value),
        (status = 503, description = "Cloudflare not configured")
    )
)]
pub async fn analytics(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let client = cf_client(&state)?;
    let data = client.analytics().await.map_err(AppError::internal)?;
    Ok(Json(json!({"status": "ok", "analytics": data})))
}
