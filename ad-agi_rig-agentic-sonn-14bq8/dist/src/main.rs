use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use std::sync::Arc;
use tokio::time::{interval, Duration};
use tracing::{info, warn};

mod agent;
mod config;
mod guardrails;
mod mattermost;
mod mcp_client;
mod self_healing;

use agent::{
    get_task, list_tasks, new_task_store, run_agent, AgentRunRequest, AgentTask, TaskStore,
};
use config::AppConfig;
use mattermost::run_mattermost_bot;
use self_healing::SelfHealingLoop;

#[derive(Clone)]
struct AppState {
    config: Arc<AppConfig>,
    tasks: TaskStore,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "rig_agentic=info".into()),
        )
        .init();

    let config = Arc::new(AppConfig::from_env());
    let tasks = new_task_store();

    info!(
        port = config.port,
        ollama = %config.ollama_url,
        model = %config.ollama_model,
        c3_api = %config.c3_api_url,
        c3_mcp = %config.c3_mcp_url,
        mm = %config.mm_url,
        heal_interval_secs = config.heal_interval_secs,
        "Starting rig-agentic"
    );

    let state = AppState {
        config: config.clone(),
        tasks: tasks.clone(),
    };

    // Background: self-healing loop (configurable via SELF_HEALING_ENABLED)
    if config.self_healing_enabled {
        let heal_config = config.clone();
        tokio::spawn(async move {
            let mut tick = interval(Duration::from_secs(heal_config.heal_interval_secs));
            let healer = SelfHealingLoop::new(heal_config);
            loop {
                tick.tick().await;
                if let Err(e) = healer.run_cycle().await {
                    warn!(error = %e, "Self-healing cycle failed");
                }
            }
        });
    } else {
        info!("Self-healing disabled via SELF_HEALING_ENABLED=false");
    }

    // Background: Mattermost bot
    let mm_config = config.clone();
    tokio::spawn(async move {
        run_mattermost_bot(mm_config).await;
    });

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/status", get(status))
        .route("/agent/run", post(agent_run))
        .route("/agent/tasks", get(agent_list))
        .route("/agent/tasks/{id}", get(agent_get))
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
    let task_count = state.tasks.read().await.len();
    let running = state
        .tasks
        .read()
        .await
        .iter()
        .filter(|t| t.status == agent::TaskStatus::Running)
        .count();

    Json(serde_json::json!({
        "status": "running",
        "service": "rig-agentic",
        "model": state.config.ollama_model,
        "ollama_url": state.config.ollama_url,
        "c3_api_url": state.config.c3_api_url,
        "c3_mcp_url": state.config.c3_mcp_url,
        "heal_interval_secs": state.config.heal_interval_secs,
        "mm_bot_enabled": state.config.mm_bot_token.is_some(),
        "tasks": {
            "total": task_count,
            "running": running
        }
    }))
}

async fn agent_run(
    State(state): State<AppState>,
    Json(request): Json<AgentRunRequest>,
) -> Json<serde_json::Value> {
    info!(task = %request.task, max_turns = request.max_turns, "Agent run requested");

    let config = state.config.clone();
    let tasks = state.tasks.clone();

    // Spawn agent in background
    tokio::spawn(async move {
        run_agent(config, tasks, request).await;
    });

    Json(serde_json::json!({
        "status": "started",
        "message": "Agent task started. Check /agent/tasks for status."
    }))
}

async fn agent_list(State(state): State<AppState>) -> Json<Vec<AgentTask>> {
    Json(list_tasks(&state.tasks).await)
}

async fn agent_get(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Json<serde_json::Value> {
    match get_task(&state.tasks, &id).await {
        Some(task) => Json(serde_json::to_value(task).unwrap()),
        None => Json(serde_json::json!({"error": "Task not found"})),
    }
}
