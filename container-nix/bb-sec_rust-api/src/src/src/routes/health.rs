use axum::{routing::get, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new().route("/rust/health", get(health))
}

#[utoipa::path(
    get,
    path = "/rust/health",
    tag = "health",
    responses(
        (status = 200, description = "Health check", body = Value)
    )
)]
pub async fn health() -> Json<Value> {
    Json(json!({
        "status": "ok",
        "service": "rust-api",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}
