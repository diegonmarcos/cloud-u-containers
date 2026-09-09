use serde::Serialize;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub enum Severity {
    Critical,
    Warning,
    Info,
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Severity::Critical => write!(f, "CRITICAL"),
            Severity::Warning => write!(f, "WARNING"),
            Severity::Info => write!(f, "INFO"),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub passed: bool,
    pub details: String,
    pub duration_ms: u64,
    pub error: Option<String>,
    pub severity: Severity,
}

/// Cached SSH batch data from oci-mail
#[derive(Debug, Clone, Default)]
pub struct RemoteData {
    pub containers: String,
    pub restarts: String,
    pub disk: String,
    pub memory: String,
    pub load: String,
    pub docker_version: String,
    /// Maddy's own IMAP banner (127.0.0.1:993) — the local_mailboxes leg.
    pub imap_cap: String,
    /// Stalwart's IMAP banner (10.0.0.3:2993) — the store mail clients read.
    /// Deliberately a separate probe from imap_cap: the two stores are written
    /// by two different legs of maddy's dual-write and either can fail alone.
    pub stalwart_imap: String,
    pub quota: String,
    pub users: String,
    pub smtp25: String,
    pub webmail_internal: String,
    pub maddy_accounts: String,
    pub maddy_domains: String,
    /// Number of messages still queued for tcp://10.0.0.3:2025, i.e. written to
    /// maddy's local store but not yet mirrored into Stalwart.
    pub stalwart_queue_depth: String,
    pub all_local_ports: String,
    #[allow(dead_code)]
    pub debug_dump: String,
    // Config drift detection (5-layer)
    pub config_src_hash: String,         // Layer 1: src/config.toml.tpl hash (local git)
    pub config_dist_hash: String,        // Layer 2: dist/config.toml.tpl hash (local nix output)
    pub config_ghcr_hash: String,        // Layer 3: GHCR image template hash (on VM)
    pub config_container_tpl_hash: String, // Layer 4: running container template hash
    pub config_running: String,          // Layer 5: running config.toml key values
    pub config_host_hash: String,        // Host deployed config hash
}

/// Cached SSH batch data from oci-apps (cloud-mail-mcp container tests)
#[derive(Debug, Clone, Default)]
pub struct RemoteDataApps {
    pub mail_mcp_status: String,
    pub dns_resolve: String,
    pub imap_tls: String,
    pub smtp_tls: String,
    pub imap_wg: String,
    pub imap_login: String,
    pub smtp_auth: String,
}

/// Cached SSH batch data from gcp-proxy
#[derive(Debug, Clone, Default)]
pub struct RemoteDataProxy {
    pub caddy_l4_993: String,
    pub caddy_l4_465: String,
    pub authelia_health: String,
}

/// Complete mail health result, serializable to JSON
#[derive(Debug, Serialize)]
pub struct MailHealthResult {
    pub generated: String,
    pub duration_ms: u64,
    pub path_checks: Vec<Check>,
    pub instant_kpis: Vec<Check>,
    pub preflight: Vec<Check>,
    pub containers: Vec<Check>,
    pub network: Vec<Check>,
    pub dns_auth: Vec<Check>,
    pub internals: Vec<Check>,
    pub config_drift: Vec<Check>,
    pub e2e_delivery: Vec<Check>,
    pub summary: Summary,
    pub timers: HashMap<String, u64>,
}

#[derive(Debug, Serialize)]
pub struct Summary {
    pub total_checks: usize,
    pub passed: usize,
    pub failed: usize,
    pub warnings: usize,
    pub critical: usize,
}
