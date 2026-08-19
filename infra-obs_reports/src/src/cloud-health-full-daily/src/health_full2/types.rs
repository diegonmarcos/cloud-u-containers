use serde::Serialize;
use std::collections::HashMap;

/// Severity of a check failure
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

/// A single diagnostic check result
#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub passed: bool,
    pub details: String,
    pub duration_ms: u64,
    pub error: Option<String>,
    pub severity: Severity,
}

/// Static context loaded from cloud-data JSONs
#[allow(dead_code)]
pub struct Context {
    pub consolidated: serde_json::Value,
    pub topology: Option<serde_json::Value>,
    pub caddy_routes: Option<serde_json::Value>,
    pub vms: Vec<VmInfo>,
    pub services: Vec<ServiceInfo>,
    pub caddy_route_list: Vec<CaddyRoute>,
    pub service_ports: HashMap<String, u16>,
    pub bearer_token: Option<String>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct VmInfo {
    pub vm_id: String,
    pub alias: String,
    pub pub_ip: String,
    pub wg_ip: String,
    pub cloud_name: String,
    pub cloud_zone: String,
    pub rescue_port: u16,
    pub cpus: u32,
    pub ram_gb: f64,
    pub shape: String,
    pub provider: String,
    pub cost: String,
    pub declared_services: Vec<String>,
    pub public_ports: Vec<PublicPort>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct PublicPort {
    pub port: u16,
    pub proto: String,
    pub desc: String,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct ServiceInfo {
    pub name: String,
    pub category: String,
    pub vm_id: String,
    pub vm_alias: String,
    pub folder: String,
    pub domain: Option<String>,
    pub port: Option<u16>,
    pub dns: Option<String>,
    pub upstream: Option<String>,
    pub containers: Vec<ContainerDecl>,
    pub enabled: bool,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct ContainerDecl {
    pub key: String,
    pub container_name: String,
    pub image: String,
    pub port: Option<u16>,
    pub dns: Option<String>,
    pub healthcheck: Option<String>,
    /// One-shot init container — `init_job: true` in build.json.
    /// Health reports treat Exited(0) / Exited(1) as success, not a crash.
    pub init_job: bool,
    /// WG-only container — `public: false` in build.json.
    /// Cross-VM public probes are skipped (can't reach by design).
    pub public: bool,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct CaddyRoute {
    pub domain: String,
    pub upstream: String,
    pub comment: String,
    pub auth: Option<String>,
}

/// VM batch data from /opt/health/latest.json (rsync agent)
#[derive(Debug, Clone, Serialize, Default)]
pub struct VmBatchData {
    pub alias: String,
    pub reachable: bool,
    pub docker_version: String,
    pub disk_pct: String,
    pub disk_used: String,
    pub disk_total: String,
    pub mem_pct: u32,
    pub mem_used: String,
    pub mem_total: String,
    pub load: String,
    pub uptime: String,
    pub swap: String,
    pub containers: Vec<ContainerHealth>,
    pub containers_running: u32,
    pub containers_total: u32,
    pub raw_json: Option<serde_json::Value>,
}

/// Container status from docker ps on VM
#[derive(Debug, Clone, Serialize)]
pub struct ContainerHealth {
    pub name: String,
    pub up: bool,
    pub healthy: bool,
    pub status: String,
    pub health_state: String,
    pub image: String,
}

/// Shared diagnostic runtime state passed between layers
#[allow(dead_code)]
pub struct DiagContext<'a> {
    pub ctx: &'a Context,
    pub reachable_vms: Vec<String>,
    pub ssh_ok_vms: Vec<String>,
    pub docker_ok_vms: Vec<String>,
    pub vm_batch: HashMap<String, VmBatchData>,
}

/// All layer results, serializable
#[derive(Debug, Serialize)]
pub struct LayerResults {
    pub generated: String,
    pub duration_ms: u64,
    pub self_check: Vec<Check>,
    pub wg_mesh: Vec<Check>,
    pub platform: Vec<Check>,
    pub containers: Vec<Check>,
    pub private_urls: Vec<Check>,
    pub public_urls: Vec<Check>,
    pub cross_checks: Vec<Check>,
    pub external: Vec<Check>,
    pub drift: Vec<Check>,
    pub security: Vec<Check>,
    pub email_e2e: Vec<Check>,
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
