use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct ExportedContainer {
    pub vm_alias: String,
    pub container_name: String,
    pub export_path: String,
    pub file_count: usize,
    pub total_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct YaraHit {
    pub vm: String,
    pub container: String,
    pub file_path: String,
    pub rule_name: String,
    pub severity: String,
    pub file_hash: String,
    pub file_size: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SiemAlert {
    pub timestamp: String,
    pub vm: String,
    pub severity: String,
    pub rule: String,
    pub file: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ThreatIntelMatch {
    pub source: String,
    pub indicator: String,
    pub indicator_type: String,
    pub matched_in: String,
    pub confidence: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Correlation {
    pub description: String,
    pub severity: String,
    pub sources: Vec<String>,
    pub evidence: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct JournalAlert {
    pub vm: String,
    pub category: String, // "ssh_bruteforce", "docker_event", "oom_kill", "systemd_failure"
    pub count: usize,
    pub severity: String,
    pub details: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeIssue {
    pub vm: String,
    pub category: String, // "privileged_container", "host_network", "cap_sys_admin", "unexpected_process", "suspicious_connection"
    pub container_or_process: String,
    pub details: String,
    pub severity: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DiffChange {
    pub vm: String,
    pub container: String,
    pub change_type: String, // "new", "modified", "deleted"
    pub details: String,
}
