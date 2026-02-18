use serde::{Deserialize, Serialize};
use serde_json::Value;
use utoipa::ToSchema;

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ProfilingResponse {
    pub container: String,
    pub vm_id: String,
    pub vm_label: String,
    pub service: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    pub total_time_ms: u64,
    pub checks: Vec<DiagnosticCheckResult>,
    pub summary: ProfilingSummary,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct DiagnosticCheckResult {
    pub name: String,
    pub success: bool,
    pub time_ms: u64,
    pub data: Value,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ProfilingSummary {
    pub checks_passed: usize,
    pub checks_failed: usize,
    pub checks_total: usize,
    pub overall_status: String,
}
