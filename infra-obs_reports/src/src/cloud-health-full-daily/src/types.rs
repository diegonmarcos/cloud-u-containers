use serde::{Deserialize, Serialize};

// ── Cloud-data JSON structures ──────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct MonitoringTargets {
    #[serde(default)]
    pub endpoint_checks: Vec<EndpointCheck>,
    #[serde(default)]
    pub tls_checks: Vec<TlsCheck>,
    #[serde(default)]
    pub vms: Vec<VmTarget>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct EndpointCheck {
    /// Display name. cloud-data renamed this from `service` → `name` on
    /// 2026-04-25 in cloud-data-monitoring-targets.json. Accept both via
    /// serde alias so the report stays compatible with both schemas.
    #[serde(alias = "name")]
    pub service: String,
    pub url: String,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(from = "TlsCheckInput")]
pub struct TlsCheck {
    pub service: String,
    pub domain: String,
}

/// cloud-data-monitoring-targets.json shipped two shapes for tls_checks:
///   v1: [{ "service": "X", "domain": "x.example.com" }]
///   v2: [{ "name":    "X", "domain": "x.example.com" }]   (alias for v1)
///   v3: ["x.example.com", ...]                            (bare domains, 2026-04-25)
/// This deserializer accepts all three so the binary survives schema drift.
#[derive(Deserialize)]
#[serde(untagged)]
enum TlsCheckInput {
    Full {
        #[serde(alias = "name")]
        service: String,
        domain: String,
    },
    BareDomain(String),
}

impl From<TlsCheckInput> for TlsCheck {
    fn from(i: TlsCheckInput) -> Self {
        match i {
            TlsCheckInput::Full { service, domain } => TlsCheck { service, domain },
            TlsCheckInput::BareDomain(d) => TlsCheck { service: d.clone(), domain: d },
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct VmTarget {
    pub ip: String,
    pub name: String,
    pub user: String,
}

#[derive(Debug, Deserialize)]
pub struct DatabasesJson {
    #[serde(default)]
    pub databases: Vec<DatabaseEntry>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DatabaseEntry {
    pub service: String,
    pub container: String,
    #[serde(rename = "type")]
    pub db_type: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub vm_alias: String,
    #[serde(default)]
    pub wg_ip: String,
    pub user: Option<String>,
    pub db: Option<String>,
}

fn default_true() -> bool {
    true
}

// ── Cloud object storage (from consolidated.storage / Terraform) ────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct CloudBucket {
    pub provider: String,
    pub name: String,
    #[serde(default)]
    pub tier: String,
    #[serde(default)]
    pub size_bytes: u64,
}

// ── Firewall data ───────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FirewallRule {
    pub port: u16,
    pub proto: String,
    pub desc: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct VmFirewall {
    pub vm_name: String,
    pub public_ports: Vec<FirewallRule>,
    pub os_rules: Vec<FirewallRule>,
    pub wg_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GlobalFirewall {
    pub docker_iptables: bool,
    pub forward_policy: String,
    pub docker_subnet: String,
    pub wg_subnet: String,
}

// ── Consolidated JSON (partial — only fields we need) ───────────────

#[derive(Debug, Deserialize)]
pub struct ConsolidatedJson {
    #[serde(default)]
    pub storage: Vec<CloudBucket>,
    #[serde(default)]
    pub services: std::collections::HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub vms: std::collections::HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub vpss: std::collections::HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub firewalls: serde_json::Value,
}

// ── Service inventory (parsed from consolidated.services) ───────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceEntry {
    pub name: String,
    pub category: String,
    pub vm: String,
    pub domain: String,
    pub enabled: bool,
    pub containers: u32,
    pub port: u16,
    pub service_type: String, // "mcp", "app", "infra"
    pub has_api: bool,        // exposes REST/programmatic API (runtime-confirmed or declared)
    pub has_web_ui: bool,     // has browser-accessible web UI
    pub api_path: String,     // API base path (e.g. "/api/v1") or empty
    pub api_url: String,      // Full API URL (e.g. "https://git.diegonmarcos.com/api/v1") or empty
    pub serves_http: bool,    // routed at its domain (proxy.primary / app_hub / mail_hub); headless services (mail-puller) declare a domain for identity but serve no HTTP
}

// ── MCP server config (from .mcp.json) ──────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpServer {
    pub name: String,
    pub command: String,
    pub source_path: String,
    pub transport: String, // "stdio", "http"
}

// ── Cloud cost data ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudCost {
    pub provider: String,
    pub month: String,      // "2026-04"
    pub service: String,    // "Compute", "Storage", "Network", etc.
    pub amount: f64,
    pub usage: f64,         // usage quantity (hours, GB, requests)
    pub currency: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WgTransfer {
    pub peer: String,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

// ── Collected VM data ───────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VmData {
    pub name: String,
    pub ip: String,
    pub status: VmStatus,
    pub uptime: String,
    pub load: String,
    pub disk: String,
    pub disk_pct: u32,
    pub mem: String,
    pub mem_pct: u32,
    pub kernel: String,
    pub wg_transfer: Vec<WgTransfer>,
    pub containers_running: u32,
    pub containers_total: u32,
    pub containers_unhealthy: u32,
    pub container_list: Vec<ContainerInfo>,
    pub container_stats: Vec<ContainerStat>,
    pub unhealthy_names: Vec<String>,
    pub exited_names: Vec<String>,
    pub ssh_accepts: u32,
    pub ssh_fails: u32,
    pub sudo_count: u32,
    pub top_fail_ips: Vec<(String, u32)>,
    pub restarts: Vec<(String, u32)>,
    pub backups: Vec<BackupEntry>,
    pub failed_units: Vec<String>,
    pub wg_peers: Vec<(String, u64)>,
    pub docker_df: Vec<DockerDfEntry>,
    pub db_sizes: Vec<(String, String)>,
    pub mail_queue: Option<u32>,
    pub mail_delivered: Option<u32>,
    pub mail_failed: Option<u32>,
    pub imap_check: String,
    pub smtp25_banner: String,
    pub mail_ports_bound: String,
    pub maddy_accounts: u32,
    pub maddy_domains: String,
    pub webmail_internal_code: u16,
    pub runtime_volumes: Vec<RuntimeVolume>,
    pub oom_kills: Vec<String>,
    pub swap: String,
    pub swap_pct: u32,
    pub log_errors: Vec<(String, u32)>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub enum VmStatus {
    Healthy,
    Warning,
    Critical,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerInfo {
    pub name: String,
    pub image: String,
    pub status: String,
    pub running_for: String,
    pub image_created: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerStat {
    pub name: String,
    pub cpu: String,
    pub mem_usage: String,
    pub mem_pct: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupEntry {
    pub file: String,
    pub size_bytes: u64,
    pub epoch: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DockerDfEntry {
    pub dtype: String,
    pub count: String,
    pub size: String,
    pub reclaimable: String,
}

// ── API-collected data ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndpointResult {
    pub service: String,
    pub url: String,
    pub status_code: u16,
    pub latency_ms: u64,
    /// True when the response is Caddy's global wildcard fallback page
    /// ("wormhole"): a 200 with the auto-generated fallback HTML served for any
    /// unrouted `*.diegonmarcos.com` host/path. This is a false-green — the
    /// service is NOT actually reachable at this URL — so it must be treated as
    /// down despite the 200. `#[serde(default)]` keeps older run-state caches
    /// (without this field) deserializable.
    #[serde(default)]
    pub edge_fallback: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CertResult {
    pub domain: String,
    pub days_left: i64,
    pub expiry: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DnsResult {
    pub record_type: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhaRun {
    pub name: String,
    pub repo: String,
    pub conclusion: String,
    pub created_at: String,
    pub html_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhaWorkflow {
    pub name: String,
    pub repo: String,
    pub state: String,       // "active", "disabled_manually", etc.
    pub path: String,        // e.g. ".github/workflows/ship-oci-apps.yml"
    pub last_conclusion: String,  // from most recent run
    pub last_run_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhcrPackage {
    pub name: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DagStatus {
    pub name: String,
    pub status: String,
    pub started_at: String,
    pub schedule: String,
}

// ── GitHub repos ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GithubRepo {
    pub name: String,
    pub visibility: String,
    pub updated_at: String,
    pub language: String,
    pub disk_kb: u64,
}

// ── FinOps / VPS provider data ───────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VpsProvider {
    pub name: String,
    pub provider: String,
    pub tier: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmFinops {
    pub alias: String,
    pub provider: String,
    pub tier: String,
    pub cpu: u32,
    pub ram_gb: f64,
    pub shape: String,
    pub services: u32,
    pub containers: u32,
}

// ── Runtime volume data (discovered via SSH) ────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeVolume {
    pub name: String,
    pub size: String,
    pub container: String,
    pub mount_point: String,
}

// ── Drift detection ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageDrift {
    pub declared_only: Vec<String>,
    pub runtime_only: Vec<String>,
    pub matched: Vec<String>,
}

// ── Executive summary ───────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct ExecSummary {
    pub critical: u32,
    pub warnings: u32,
    pub ok: u32,
    pub top_issues: Vec<Issue>,
    #[serde(default)]
    pub all_issues: Vec<Issue>,
    #[serde(default)]
    pub issues_by_kind: std::collections::BTreeMap<String, u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Issue {
    pub severity: String,
    pub message: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub entity: String,
    #[serde(default)]
    pub vm: String,
    #[serde(default)]
    pub evidence_paths: Vec<String>,
}

// ── Container manifest + drift ─────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
pub struct VmContainerManifest {
    pub vm: String,
    #[serde(default)]
    pub services: Vec<ManifestService>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct ManifestService {
    pub name: String,
    #[serde(default)]
    pub dir: String,
    #[serde(default)]
    pub images: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerDrift {
    pub vm_name: String,
    pub expected_not_running: Vec<String>,
    pub running_not_declared: Vec<String>,
    pub image_mismatch: Vec<(String, String, String)>,
}

// ── AI usage data (from Claude stats-cache.json) ───────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiModelUsage {
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_create_tokens: u64,
    pub estimated_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiDailyActivity {
    pub date: String,
    pub messages: u64,
    pub sessions: u64,
    pub tool_calls: u64,
    pub tokens: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AiSummary {
    pub models: Vec<AiModelUsage>,
    pub daily: Vec<AiDailyActivity>,
    pub total_sessions: u64,
    pub total_messages: u64,
    pub total_cost_usd: f64,
    pub first_session: String,
}

// ── Web analytics (Umami) ──────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UmamiStats {
    pub pageviews: u64,
    pub visitors: u64,
    pub visits: u64,
    pub bounces: u64,
    pub total_time: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UmamiSite {
    pub id: String,
    pub name: String,
    pub domain: String,
    pub current_month: UmamiStats,
    pub last_6_months: Vec<(String, UmamiStats)>, // (month, stats)
    pub top_pages: Vec<(String, u64)>,             // (url, views)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerCpuRank {
    pub rank: u32,
    pub container: String,
    pub vm: String,
    pub cpu_pct: String,
    pub mem_usage: String,
    pub mem_pct: String,
    pub uptime_hours: f64,
    pub cpu_hours: f64,
    pub mem_gb_hours: f64,
}

// ── Web analytics (Matomo — comparison source) ───────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MatomoMonthly {
    pub month: String,
    pub visits: u64,
    pub pageviews: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MatomoSite {
    pub id: u32,
    pub name: String,
    pub url: String,
    pub total_visits: u64,
    pub total_pageviews: u64,
    pub monthly: Vec<MatomoMonthly>,
}

// ── Mail health data (incorporated from cloud-mail-full-report) ──

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailCheck {
    pub name: String,
    pub passed: bool,
    pub details: String,
    pub severity: String, // "critical", "warning", "info"
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MailHealthData {
    pub outbound_path: Vec<MailCheck>,
    pub inbound_path: Vec<MailCheck>,
    pub dns_auth: Vec<MailCheck>,
    pub tls_ports: Vec<MailCheck>,
    pub containers: Vec<MailCheck>,
    pub internals: Vec<MailCheck>,
    pub stalwart: Vec<MailCheck>,
    pub summary: MailHealthSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MailHealthSummary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub critical: usize,
    pub warnings: usize,
}

// ── Full report data ────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct ReportData {
    pub date: String,
    pub time: String,
    pub vms: Vec<VmData>,
    pub endpoints: Vec<EndpointResult>,
    pub certs: Vec<CertResult>,
    pub dns: Vec<DnsResult>,
    pub gha_runs: Vec<GhaRun>,
    pub gha_workflows: Vec<GhaWorkflow>,
    pub ghcr_packages: Vec<GhcrPackage>,
    pub ghcr_total: usize,
    pub github_disk_kb: u64,
    pub dags: Vec<DagStatus>,
    pub databases: Vec<DatabaseEntry>,
    pub fleet_running: u32,
    pub fleet_total: u32,
    pub fleet_unhealthy: u32,
    pub drift: Vec<StorageDrift>,
    pub exec_summary: ExecSummary,
    pub container_drift: Vec<ContainerDrift>,
    pub cloud_buckets: Vec<CloudBucket>,
    pub cloud_costs: Vec<CloudCost>,
    pub services: Vec<ServiceEntry>,
    pub repos: Vec<GithubRepo>,
    pub mcp_servers: Vec<McpServer>,
    pub vps_providers: Vec<VpsProvider>,
    pub vm_finops: Vec<VmFinops>,
    pub total_services: usize,
    pub total_containers: u32,
    pub total_domains: usize,
    pub generation_duration_ms: u64,
    pub ai: Option<AiSummary>,
    pub umami_sites: Vec<UmamiSite>,
    pub container_cpu_ranking: Vec<ContainerCpuRank>,
    pub firewalls: Vec<VmFirewall>,
    pub global_firewall: GlobalFirewall,
    pub mail_health: Option<MailHealthData>,
    pub matomo_sites: Vec<MatomoSite>,
    /// Appendix: consolidated output from `cloud-health-full-2` when it ran
    /// earlier in the same build pipeline. Empty when Daily runs standalone.
    #[serde(default)]
    pub appendix_md: String,
    #[serde(default)]
    pub appendix_stack: Option<serde_json::Value>,
    #[serde(default)]
    pub appendix_full: Option<serde_json::Value>,
}
