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
use models::wake::WakeState;

pub struct AppState {
    pub config: AppConfig,
    pub http: reqwest::Client,
    pub wake: WakeState,
}

#[derive(OpenApi)]
#[openapi(
    paths(
        routes::health::health,
        routes::vm_control::start_vm,
        routes::vm_control::stop_vm,
        routes::vm_control::reset_vm,
        routes::vm_status::vm_status,
        routes::wake::trigger_wake,
        routes::wake::wake_status,
        routes::containers::list_containers,
        routes::containers::start_container,
        routes::containers::stop_container,
        routes::containers::restart_container,
        routes::flex::flex_wake,
        routes::flex::flex_sleep,
        routes::flex::flex_service_status,
        routes::flex::flex_status_all,
        routes::flex::flex_wake_all,
        routes::flex::flex_sleep_all,
        routes::cloudflare::list_dns,
        routes::cloudflare::create_dns,
        routes::cloudflare::update_dns,
        routes::cloudflare::delete_dns,
        routes::cloudflare::purge_cache,
        routes::cloudflare::zone_info,
        routes::cloudflare::list_firewall,
        routes::cloudflare::create_firewall,
        routes::cloudflare::analytics,
        routes::ondemand::ondemand_status,
        routes::ondemand::ondemand_vm_health,
        routes::ondemand::ondemand_vm_start,
        routes::ondemand::ondemand_vm_stop,
        routes::ondemand::ondemand_vm_reset,
        routes::ondemand::ondemand_container_status,
        routes::ondemand::ondemand_container_start,
        routes::ondemand::ondemand_container_stop,
        routes::ondemand::ondemand_service_start,
        routes::ondemand::ondemand_service_stop,
    ),
    components(schemas(
        models::api_response::ApiResponse,
        models::api_response::ContainerInfo,
        models::api_response::VmStatusResponse,
        models::api_response::DnsRecord,
        models::api_response::DnsRecordCreate,
        models::api_response::CachePurgeRequest,
        models::api_response::FirewallRule,
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
        wake: WakeState::default(),
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
