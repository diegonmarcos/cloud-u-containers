use axum::Router;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

mod config;
mod error;
mod models;
mod routes;
mod services;

use config::AppConfig;

pub struct AppState {
    pub config: AppConfig,
    pub http: reqwest::Client,
    pub gcp_token_cache: services::gcp::TokenCache,
}

#[derive(OpenApi)]
#[openapi(
    paths(
        routes::ondemand::health_all,
        routes::ondemand::health_containers_by_vm,
        routes::ondemand::health_containers_by_service,
        routes::ondemand::health_proxied_by_services,
        // Legacy flex-shortcut endpoints
        routes::ondemand::ondemand_vm_start,
        routes::ondemand::ondemand_vm_stop,
        routes::ondemand::ondemand_vm_reset,
        routes::ondemand::ondemand_container_status,
        routes::ondemand::ondemand_container_start,
        routes::ondemand::ondemand_container_stop,
        routes::ondemand::ondemand_container_restart,
        routes::ondemand::ondemand_service_start,
        routes::ondemand::ondemand_service_stop,
        // Generalized per-VM endpoints
        routes::ondemand::vm_health,
        routes::ondemand::vm_start,
        routes::ondemand::vm_stop,
        routes::ondemand::vm_reset,
        routes::ondemand::vm_container_status,
        routes::ondemand::vm_container_start,
        routes::ondemand::vm_container_stop,
        routes::ondemand::vm_container_restart,
        routes::ondemand::vm_service_start,
        routes::ondemand::vm_service_stop,
    ),
    components(schemas(
        models::api_response::ApiResponse,
        models::api_response::ContainerInfo,
        models::api_response::VmStatusResponse,
    ))
)]
struct ApiDoc;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "rust_api=info,tower_http=info".into()),
        )
        .init();

    let config = AppConfig::load();
    let listen_addr = format!("0.0.0.0:{}", config.port);

    let state = Arc::new(AppState {
        config,
        http: reqwest::Client::new(),
        gcp_token_cache: services::gcp::new_token_cache(),
    });

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .merge(SwaggerUi::new("/rust/api-docs").url("/rust/api-docs/openapi.json", ApiDoc::openapi()))
        .merge(routes::router())
        .layer(cors)
        .with_state(state);

    tracing::info!("Rust API listening on {listen_addr}");
    let listener = tokio::net::TcpListener::bind(&listen_addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
