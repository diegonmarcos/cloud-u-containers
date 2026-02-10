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
