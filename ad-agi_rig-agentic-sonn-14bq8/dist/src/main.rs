use axum::{extract::State, routing::get, Json, Router};
use std::sync::Arc;
use tokio::time::{interval, Duration};
use tracing::{info, warn};

mod config;
mod kg;
mod self_healing;

use config::AppConfig;
use kg::KgClient;
use self_healing::SelfHealingLoop;

#[derive(Clone)]
struct AppState {
    config: Arc<AppConfig>,
    kg: Arc<KgClient>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "rig_infra=info".into()),
        )
        .init();

    let config = Arc::new(AppConfig::from_env());
    let kg = Arc::new(KgClient::new(&config.surreal_url, &config.surreal_pass));

    info!(
        port = config.port,
        surreal = %config.surreal_url,
        interval_secs = config.heal_interval_secs,
        "Starting rig-infra"
    );

    let state = AppState {
        config: config.clone(),
        kg: kg.clone(),
    };

    // Background: self-healing loop
    let heal_config = config.clone();
    let heal_kg = kg.clone();
    tokio::spawn(async move {
        let mut tick = interval(Duration::from_secs(heal_config.heal_interval_secs));
        let healer = SelfHealingLoop::new(heal_kg, heal_config);
        loop {
            tick.tick().await;
            if let Err(e) = healer.run_cycle().await {
                warn!(error = %e, "Self-healing cycle failed");
            }
        }
    });

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/status", get(status))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", config.port);
    info!("Listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn health() -> &'static str {
    "OK"
}

async fn status(State(state): State<AppState>) -> Json<serde_json::Value> {
    let vm_count = state.kg.count_table("vm").await.unwrap_or(0);
    let svc_count = state.kg.count_table("service").await.unwrap_or(0);
    let audit_count = state.kg.count_table("audit_log").await.unwrap_or(0);

    Json(serde_json::json!({
        "status": "running",
        "heal_interval_secs": state.config.heal_interval_secs,
        "kg": {
            "vms": vm_count,
            "services": svc_count,
            "audit_entries": audit_count
        }
    }))
}
