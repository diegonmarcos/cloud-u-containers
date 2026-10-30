//! Shared server state. Cloned cheaply (everything is `Arc`).

use fincept_agents_investors::Persona;
use fincept_datahub::DataHub;
use fincept_mcp::Registry as McpRegistry;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub hub: Arc<DataHub>,
    pub personas: Arc<HashMap<String, Persona>>,
    pub mcp: Arc<McpRegistry>,
    pub version: &'static str,
}

impl AppState {
    pub fn try_new() -> anyhow::Result<Self> {
        let hub = DataHub::new();
        let personas = fincept_agents_investors::InvestorAgent::default_roster()
            .map_err(|e| anyhow::anyhow!("persona roster: {e}"))?;
        let mcp = McpRegistry::with_defaults();
        Ok(Self {
            hub,
            personas: Arc::new(personas),
            mcp: Arc::new(mcp),
            version: env!("CARGO_PKG_VERSION"),
        })
    }
}
