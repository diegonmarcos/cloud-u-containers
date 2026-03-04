use crate::config::AppConfig;
use crate::mcp_client::{connect_mcp, list_mcp_tools};
use chrono::Utc;
use rig::providers::ollama;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{error, info};
use uuid::Uuid;

/// Status of an agent task.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum TaskStatus {
    Running,
    Completed,
    Failed,
}

/// A single step in the agent's execution trace.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentStep {
    pub iteration: usize,
    pub timestamp: String,
    pub action: String,
    pub detail: String,
}

/// Result of an agent task.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentTask {
    pub id: String,
    pub task: String,
    pub status: TaskStatus,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub result: Option<String>,
    pub steps: Vec<AgentStep>,
    pub error: Option<String>,
}

/// Request to start an agent task.
#[derive(Deserialize)]
pub struct AgentRunRequest {
    pub task: String,
    #[serde(default = "default_max_turns")]
    pub max_turns: usize,
}

fn default_max_turns() -> usize {
    15
}

/// Shared state for tracking running agent tasks.
pub type TaskStore = Arc<RwLock<Vec<AgentTask>>>;

pub fn new_task_store() -> TaskStore {
    Arc::new(RwLock::new(Vec::new()))
}

const SYSTEM_PROMPT: &str = r#"You are an autonomous infrastructure agent managing Diego's cloud infrastructure.

## Your environment
- 5 VMs across GCP and OCI (gcp-proxy, oci-mail, oci-analytics, oci-apps, oci-apps-1)
- Services run as Docker containers managed by docker-compose
- All traffic flows: Cloudflare → Caddy (gcp-proxy) → WireGuard → target VM
- C3 API provides health checks, container lifecycle, security scans, and tests

## How to work
1. ALWAYS start by gathering information (health checks, logs, status) before taking action
2. Use the most specific tool available — prefer health_tier1 for quick checks, health_tier3 for deep checks
3. After making changes (restart, start, stop), VERIFY with a health check or test
4. If something is wrong, check logs first with container_logs before restarting blindly
5. For security issues, run security_scan or security_docker
6. Send notify_send for important findings or completed critical repairs

## VM aliases
- gcp-proxy (35.226.147.64) — Caddy, Authelia, Vaultwarden, ntfy
- oci-mail (130.110.251.193) — Mailu, Syncthing, Radicale
- oci-analytics (129.151.228.66) — Matomo, Windmill
- oci-apps (82.70.229.129) — C3 API, Crawlee, this agent
- oci-apps-1 (144.24.196.72) — PhotoPrism, NocoDB, Code Server, AFFiNE

## Response format
When you have completed your task and verified the result, end your response with the word DONE on its own line.
If you cannot complete the task, explain why and end with FAILED on its own line."#;

/// Run the agentic loop for a task.
pub async fn run_agent(
    config: Arc<AppConfig>,
    task_store: TaskStore,
    request: AgentRunRequest,
) {
    let task_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    let task = AgentTask {
        id: task_id.clone(),
        task: request.task.clone(),
        status: TaskStatus::Running,
        started_at: now.clone(),
        finished_at: None,
        result: None,
        steps: vec![AgentStep {
            iteration: 0,
            timestamp: now,
            action: "start".to_string(),
            detail: format!("Starting agent task: {}", request.task),
        }],
        error: None,
    };

    // Register task
    {
        let mut store = task_store.write().await;
        store.push(task);
    }

    // Run the agent
    let result = execute_agent_loop(
        &config,
        &request.task,
        request.max_turns,
    )
    .await;

    // Update task with result
    let mut store = task_store.write().await;
    if let Some(task) = store.iter_mut().find(|t| t.id == task_id) {
        task.finished_at = Some(Utc::now().to_rfc3339());
        match result {
            Ok((response, steps)) => {
                task.status = if response.contains("FAILED") {
                    TaskStatus::Failed
                } else {
                    TaskStatus::Completed
                };
                task.result = Some(response);
                task.steps.extend(steps);
            }
            Err(e) => {
                task.status = TaskStatus::Failed;
                task.error = Some(e);
                task.steps.push(AgentStep {
                    iteration: 0,
                    timestamp: Utc::now().to_rfc3339(),
                    action: "error".to_string(),
                    detail: "Agent loop failed".to_string(),
                });
            }
        }
    }
}

/// Execute the rig-core agent with Ollama + MCP tools from c3-api.
async fn execute_agent_loop(
    config: &AppConfig,
    task: &str,
    max_turns: usize,
) -> Result<(String, Vec<AgentStep>), String> {
    info!(task = task, max_turns = max_turns, "Starting agent loop");

    // Connect to MCP server (c3-api) and discover tools
    let mcp_url = format!("{}/mcp", config.c3_mcp_url);
    let mcp_client = connect_mcp(&mcp_url).await?;
    let tools = list_mcp_tools(&mcp_client).await?;

    info!(tool_count = tools.len(), "MCP tools loaded");

    // Build Ollama client — reads OLLAMA_API_BASE_URL env var
    let ollama_client = ollama::Client::from_env();

    // Build agent with MCP tools
    let agent = ollama_client
        .agent(&config.ollama_model)
        .preamble(SYSTEM_PROMPT)
        .rmcp_tools(tools, mcp_client.peer().to_owned())
        .build();

    // Run the prompt with multi-turn tool calling
    let response = agent
        .prompt(task)
        .multi_turn(max_turns)
        .send()
        .await
        .map_err(|e| format!("Agent prompt failed: {}", e))?;

    info!(response_len = response.len(), "Agent completed");

    let steps = vec![AgentStep {
        iteration: 1,
        timestamp: Utc::now().to_rfc3339(),
        action: "complete".to_string(),
        detail: if response.len() > 500 {
            format!("{}...", &response[..500])
        } else {
            response.clone()
        },
    }];

    Ok((response, steps))
}

/// Get a task by ID.
pub async fn get_task(store: &TaskStore, id: &str) -> Option<AgentTask> {
    let store = store.read().await;
    store.iter().find(|t| t.id == id).cloned()
}

/// Get all tasks (most recent first).
pub async fn list_tasks(store: &TaskStore) -> Vec<AgentTask> {
    let store = store.read().await;
    let mut tasks: Vec<AgentTask> = store.iter().rev().take(20).cloned().collect();
    tasks.reverse();
    tasks
}

/// Run agent from a Mattermost message and return the response text.
pub async fn run_agent_chat(
    config: Arc<AppConfig>,
    message: &str,
    chat_history: Vec<String>,
) -> Result<String, String> {
    info!(message = message, "Running agent chat");

    // Connect to MCP server and discover tools
    let mcp_url = format!("{}/mcp", config.c3_mcp_url);
    let mcp_client = connect_mcp(&mcp_url).await?;
    let tools = list_mcp_tools(&mcp_client).await?;

    // Build Ollama client — reads OLLAMA_API_BASE_URL env var
    let ollama_client = ollama::Client::from_env();

    let agent = ollama_client
        .agent(&config.ollama_model)
        .preamble(SYSTEM_PROMPT)
        .rmcp_tools(tools, mcp_client.peer().to_owned())
        .build();

    // Build context from chat history
    let context = if chat_history.is_empty() {
        message.to_string()
    } else {
        let history = chat_history
            .iter()
            .enumerate()
            .map(|(i, m)| format!("[Turn {}]: {}", i + 1, m))
            .collect::<Vec<_>>()
            .join("\n");
        format!("Previous conversation:\n{}\n\nCurrent message: {}", history, message)
    };

    let response = agent
        .prompt(&context)
        .multi_turn(15)
        .send()
        .await
        .map_err(|e| {
            error!(error = %e, "Agent chat failed");
            format!("Agent error: {}", e)
        })?;

    Ok(response)
}
