use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ApiResponse {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vm: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ContainerInfo {
    pub name: String,
    pub status: String,
    pub ports: String,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct VmStatusResponse {
    pub vm_id: String,
    pub status: String,
    pub label: String,
    pub ping: bool,
    pub ssh: bool,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct DnsRecord {
    pub id: String,
    #[serde(rename = "type")]
    pub record_type: String,
    pub name: String,
    pub content: String,
    pub proxied: bool,
    pub ttl: u32,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct DnsRecordCreate {
    #[serde(rename = "type")]
    pub record_type: String,
    pub name: String,
    pub content: String,
    #[serde(default)]
    pub proxied: bool,
    #[serde(default = "default_ttl")]
    pub ttl: u32,
}

fn default_ttl() -> u32 {
    1
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct CachePurgeRequest {
    #[serde(default)]
    pub purge_everything: bool,
    #[serde(default)]
    pub files: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct FirewallRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub expression: String,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}
