use crate::config::AppConfig;
use std::collections::HashSet;
use tracing::{info, warn};

/// Infrastructure guardrails: tool filtering, audit logging, rate limiting.
pub struct InfraGuardrail {
    pub max_turns: usize,
    pub denied_tools: HashSet<String>,
    pub allowed_tools: HashSet<String>,
}

impl InfraGuardrail {
    pub fn from_config(config: &AppConfig) -> Self {
        let guardrail = Self {
            max_turns: config.guardrail_max_turns,
            denied_tools: config.guardrail_denied_tools.iter().cloned().collect(),
            allowed_tools: config.guardrail_allowed_tools.iter().cloned().collect(),
        };

        info!(
            max_turns = guardrail.max_turns,
            denied_count = guardrail.denied_tools.len(),
            denied = ?guardrail.denied_tools,
            allowed_count = guardrail.allowed_tools.len(),
            allowed = ?guardrail.allowed_tools,
            mode = if !guardrail.allowed_tools.is_empty() { "allowlist" } else { "denylist" },
            "Guardrails initialized"
        );

        guardrail
    }

    /// Filter tools based on allowlist (if set) or denylist.
    /// Allowlist takes precedence: if non-empty, ONLY those tools are allowed.
    pub fn filter_tools(&self, tools: Vec<rmcp::model::Tool>) -> (Vec<rmcp::model::Tool>, usize) {
        let total = tools.len();

        // Allowlist mode: only keep explicitly allowed tools
        if !self.allowed_tools.is_empty() {
            let (allowed, denied): (Vec<_>, Vec<_>) = tools
                .into_iter()
                .partition(|t| self.allowed_tools.contains(t.name.as_ref()));

            let denied_count = denied.len();
            for tool in &denied {
                warn!(tool = %tool.name, "GUARDRAIL: tool blocked by allowlist");
            }

            info!(
                total = total,
                allowed = allowed.len(),
                blocked = denied_count,
                mode = "allowlist",
                "GUARDRAIL: tool filtering complete"
            );

            return (allowed, denied_count);
        }

        // Denylist mode: remove explicitly denied tools
        if self.denied_tools.is_empty() {
            return (tools, 0);
        }

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
            mode = "denylist",
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
