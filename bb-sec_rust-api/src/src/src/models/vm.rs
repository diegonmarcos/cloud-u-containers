use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmInfo {
    pub id: String,
    pub provider: String,
    pub state: String,
}

/// Validates a VM ID to prevent injection
pub fn validate_vm_id(id: &str) -> bool {
    id.len() < 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Validates a container name to prevent injection
pub fn validate_container_name(name: &str) -> bool {
    name.len() < 128
        && !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}
