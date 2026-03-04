use crate::config::AppConfig;
use std::collections::HashSet;
use tracing::{info, warn};

/// Infrastructure guardrails: tool filtering, audit logging, rate limiting.
pub struct InfraGuardrail {
    pub max_turns: usize,
    pub denied_tools: HashSet<String>,
}

impl InfraGuardrail {
    pub fn from_config(config: &AppConfig) -> Self {
        let guardrail = Self {
            max_turns: config.guardrail_max_turns,
            denied_tools: config.guardrail_denied_tools.iter().cloned().collect(),
        };

        info!(
            max_turns = guardrail.max_turns,
            denied_count = guardrail.denied_tools.len(),
            denied = ?guardrail.denied_tools,
            "Guardrails initialized"
        );

        guardrail
    }

    /// Filter denied tools from the MCP tool list. Returns (allowed, denied_count).
    pub fn filter_tools(&self, tools: Vec<rmcp::model::Tool>) -> (Vec<rmcp::model::Tool>, usize) {
        if self.denied_tools.is_empty() {
            return (tools, 0);
        }

        let total = tools.len();
        let (allowed, denied): (Vec<_>, Vec<_>) = tools
            .into_iter()
            .partition(|t| !self.denied_tools.contains(t.name.as_ref()));

        let denied_count = denied.len();
        for tool in &denied {
            warn!(tool = %tool.name, "GUARDRAIL: tool denied by denylist");
        }

        info!(
            total = total,
            allowed = allowed.len(),
            denied = denied_count,
            "GUARDRAIL: tool filtering complete"
        );

        (allowed, denied_count)
    }

    /// Log the start of an agent execution.
    pub fn audit_start(&self, task: &str, tool_count: usize) {
        info!(
            task = task,
            tools_available = tool_count,
            max_turns = self.max_turns,
            "AUDIT: agent execution started"
        );
    }

    /// Log the completion of an agent execution.
    pub fn audit_complete(&self, task: &str, response_len: usize) {
        info!(
            task = task,
            response_len = response_len,
            "AUDIT: agent execution completed"
        );
    }

    /// Log a failed agent execution.
    pub fn audit_error(&self, task: &str, error: &str) {
        warn!(
            task = task,
            error = error,
            "AUDIT: agent execution failed"
        );
    }
}
