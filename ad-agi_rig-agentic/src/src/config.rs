use std::env;

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub port: u16,
    pub ollama_url: String,
    pub ollama_model: String,
    pub c3_api_url: String,
    pub c3_mcp_url: String,
    pub mm_url: String,
    pub mm_bot_token: Option<String>,
    pub heal_interval_secs: u64,
    pub docker_socket: String,
    pub guardrail_max_turns: usize,
    pub guardrail_denied_tools: Vec<String>,
}

impl AppConfig {
    pub fn from_env() -> Self {
        let c3_api_url = env::var("C3_API_URL")
            .unwrap_or_else(|_| "http://c3-mcp-api:8080".into());
        let c3_mcp_url = env::var("C3_MCP_URL")
            .unwrap_or_else(|_| "http://c3-mcp-api:3100".into());

        Self {
            port: env::var("RIG_PORT")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(8090),
            ollama_url: env::var("OLLAMA_URL")
                .unwrap_or_else(|_| "http://10.0.0.8:11434".into()),
            ollama_model: env::var("OLLAMA_MODEL")
                .unwrap_or_else(|_| "MFDoom/deepseek-r1-tool-calling:14b-qwen-distill-q8_0".into()),
            c3_api_url,
            c3_mcp_url,
            mm_url: env::var("MATTERMOST_URL")
                .unwrap_or_else(|_| "http://mattermost:8065".into()),
            mm_bot_token: env::var("MM_BOT_TOKEN").ok(),
            heal_interval_secs: env::var("HEAL_INTERVAL_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(300),
            docker_socket: env::var("DOCKER_HOST")
                .unwrap_or_else(|_| "unix:///var/run/docker.sock".into()),
            guardrail_max_turns: env::var("GUARDRAIL_MAX_TURNS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(20),
            guardrail_denied_tools: env::var("GUARDRAIL_DENIED_TOOLS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect(),
        }
    }
}
