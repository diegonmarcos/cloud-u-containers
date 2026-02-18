# Cloud Control

> **Product Spec & Architecture Design**
> **Version:** 0.1.0
> **Status:** Design
> **Type:** Rust Library + API

---

## 1. Problem Statement

**Need:** A centralized "brain" for cloud infrastructure management that powers:
- REST API for web dashboards
- CLI tool for local debugging
- Comprehensive health monitoring and reporting

**Current State:** Python Flask API at `back-data_know_center/0_api/` with partial implementation.

**Solution:** Rust library (`control_lib`) with independent functions that both the API server and CLI can consume.

---

## 2. Product Overview

### 2.1 API Endpoints (via `control_api`)

```
/health         - API health checks
/vms            - Virtual machine management
/services       - Service status and control
/containers     - Container operations
/domains        - Domain and SSL status
/topology       - Infrastructure visualization
/cost           - Cost tracking
/monitor        - Real-time monitoring
/wake           - Wake-on-demand triggers
/dashboard      - Aggregated dashboard data
/actions        - Administrative actions
```

### 2.2 CLI Commands (via `control_cli`)

```
cloud-control [COMMAND]

COMMANDS:
    health      Health checks (external + internal)
    vms         VM status and control
    services    Service information
    containers  Container operations
    domains     Domain and SSL checks
    topology    Infrastructure topology
    cost        Cost summary
    monitor     Real-time monitoring
    wake        Wake-on-demand
    export      Export reports (JSON/MD)
    status      Quick overall status
```

---

## 3. Architecture

### 3.1 System Overview

```
+-------------------------------------------------------------------------+
|                         WEB DASHBOARDS                                   |
|  +----------------------------+  +----------------------------+          |
|  |     cloud_control.html     |  |     architecture.html      |          |
|  |  (Health, Topology, Ops)   |  |   (Infrastructure View)    |          |
|  +-------------+--------------+  +-------------+--------------+          |
|                |                               |                         |
|                +---------------+---------------+                         |
|                                |                                         |
|                                v                                         |
|                    +-----------------------+                             |
|                    |     control_api       |                             |
|                    |   (Axum HTTP Server)  |                             |
|                    +----------+------------+                             |
|                               |                                          |
+-------------------------------+------------------------------------------+
                                |
                                v
                    +------------------------+
                    |      control_lib       |
                    |   (Rust Core Library)  |
                    |                        |
                    |  +------------------+  |
                    |  | health/          |  |
                    |  | vms/             |  |
                    |  | services/        |  |
                    |  | containers/      |  |
                    |  | domains/         |  |
                    |  | topology/        |  |
                    |  | cost/            |  |
                    |  | monitor/         |  |
                    |  | wake/            |  |
                    |  | export/          |  |
                    |  +------------------+  |
                    +------------------------+
                                |
                    +-----------+-----------+
                    |                       |
                    v                       v
            +---------------+       +---------------+
            |  control_cli  |       |   SSH/API     |
            | (Local Debug) |       |  (Cloud VMs)  |
            +---------------+       +---------------+
```

### 3.2 Dashboard Features (cloud_control.html)

Based on the existing dashboard navigation:

| Category | Tab | Features |
|----------|-----|----------|
| **Topology** | Resource > Graphs | Infrastructure graph visualization |
| | Resource > Tables | App table, Data table, Containers table |
| | Security > Graphs | Security topology visualization |
| | Security > Table | Security configuration table |
| **Health** | Metrics | VM health metrics, container status |
| | Profiling | Performance profiling data |
| **Security** | Security | Security posture overview |
| | Analytics | Security analytics |
| | Logs | Security audit logs |
| **Ops** | Cost > Infrastructure | Cloud provider costs |
| | Cost > AI | AI service costs (Claude, etc.) |
| | Capacity | Resource capacity planning |
| **Apps** | - | Cloud management applications |

### 3.3 Module Architecture

```
cloud_control/
|-- Cargo.toml                  # Workspace definition
|
|-- crates/
|   |
|   |-- control_lib/            # ================================
|   |   |-- Cargo.toml          # CORE LIBRARY (the "brain")
|   |   +-- src/
|   |       |-- lib.rs          # Public API exports
|   |       |
|   |       |-- health/         # Health checks
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # HealthReport, HealthStatus
|   |       |   |-- external.rs     # ping(), check_http(), check_ssl()
|   |       |   |-- internal.rs     # check_docker(), check_disk()
|   |       |   |-- report.rs       # generate_report()
|   |       |   +-- export.rs       # export_json(), export_markdown()
|   |       |
|   |       |-- vms/            # VM management
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # Vm, VmStatus, VmDetails
|   |       |   |-- registry.rs     # list_vms(), get_vm()
|   |       |   |-- status.rs       # get_vm_status(), get_vm_details()
|   |       |   +-- control.rs      # start_vm(), stop_vm(), reset_vm()
|   |       |
|   |       |-- services/       # Service management
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # Service, ServiceStatus
|   |       |   |-- registry.rs     # list_services(), get_service()
|   |       |   +-- status.rs       # get_service_status()
|   |       |
|   |       |-- containers/     # Container operations
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # Container, ContainerStatus
|   |       |   |-- list.rs         # list_containers()
|   |       |   +-- control.rs      # start(), stop(), restart()
|   |       |
|   |       |-- domains/        # Domain management
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # Domain, DomainStatus, SslInfo
|   |       |   |-- registry.rs     # list_domains(), get_domain()
|   |       |   |-- status.rs       # check_domain_status()
|   |       |   +-- ssl.rs          # check_ssl(), get_ssl_info()
|   |       |
|   |       |-- topology/       # Infrastructure topology
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # TopologyGraph, Node, Edge
|   |       |   |-- vms.rs          # vm_topology()
|   |       |   |-- services.rs     # services_by_vm()
|   |       |   |-- containers.rs   # container_topology()
|   |       |   +-- networks.rs     # network_topology()
|   |       |
|   |       |-- cost/           # Cost tracking
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # CostSummary, CostBreakdown
|   |       |   |-- infra.rs        # infrastructure_cost()
|   |       |   +-- ai.rs           # ai_cost()
|   |       |
|   |       |-- monitor/        # Real-time monitoring
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # MonitorSummary, MetricPoint
|   |       |   |-- vms.rs          # monitor_vms()
|   |       |   |-- endpoints.rs    # monitor_endpoints()
|   |       |   +-- containers.rs   # monitor_containers()
|   |       |
|   |       |-- wake/           # Wake-on-demand
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # WakeStatus, WakeResult
|   |       |   |-- trigger.rs      # trigger_wake()
|   |       |   +-- status.rs       # wake_status()
|   |       |
|   |       |-- dashboard/      # Aggregated data
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # DashboardSummary, QuickStatus
|   |       |   |-- summary.rs      # get_summary()
|   |       |   +-- quick.rs        # get_quick_status()
|   |       |
|   |       |-- config/         # Configuration
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # AppConfig, VmConfig
|   |       |   |-- loader.rs       # load_config(), load_architecture()
|   |       |   +-- paths.rs        # get_config_paths()
|   |       |
|   |       |-- ssh/            # SSH utilities
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # SshConfig, CommandOutput
|   |       |   |-- connection.rs   # connect(), execute()
|   |       |   +-- tunnel.rs       # create_tunnel()
|   |       |
|   |       +-- error.rs        # CloudError, Result
|   |
|   |-- control_cli/            # ================================
|   |   |-- Cargo.toml          # CLI BINARY
|   |   +-- src/
|   |       |-- main.rs
|   |       |-- commands/
|   |       |   |-- mod.rs
|   |       |   |-- health.rs
|   |       |   |-- vms.rs
|   |       |   |-- services.rs
|   |       |   |-- containers.rs
|   |       |   |-- domains.rs
|   |       |   |-- topology.rs
|   |       |   |-- cost.rs
|   |       |   |-- monitor.rs
|   |       |   |-- wake.rs
|   |       |   +-- export.rs
|   |       +-- output/
|   |           |-- mod.rs
|   |           |-- table.rs
|   |           |-- progress.rs
|   |           +-- colors.rs
|   |
|   +-- control_api/            # ================================
|       |-- Cargo.toml          # API SERVER
|       +-- src/
|           |-- main.rs
|           |-- routes/
|           |   |-- mod.rs
|           |   |-- health.rs
|           |   |-- vms.rs
|           |   |-- services.rs
|           |   |-- containers.rs
|           |   |-- domains.rs
|           |   |-- topology.rs
|           |   |-- cost.rs
|           |   |-- monitor.rs
|           |   |-- wake.rs
|           |   |-- dashboard.rs
|           |   +-- actions.rs
|           +-- middleware/
|               |-- mod.rs
|               |-- auth.rs
|               +-- logging.rs
|
|-- 0.spec/
|   +-- CLOUD_CONTROL.md        # This file
|
+-- 1.ops/
    +-- build.sh
```

---

## 4. API Specification

### 4.1 Health Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/health` | GET | Simple health check | `health::ping()` |
| `/health/ready` | GET | Readiness check (DB, cache) | `health::ready()` |

### 4.2 VM Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/vms` | GET | List all VMs | `vms::list_vms()` |
| `/vms/{vmId}` | GET | Get VM info | `vms::get_vm()` |
| `/vms/{vmId}/status` | GET | Get VM health status | `vms::get_vm_status()` |
| `/vms/{vmId}/details` | GET | Get VM details (via SSH) | `vms::get_vm_details()` |
| `/vms/{vmId}/containers` | GET | List VM containers | `containers::list_containers()` |
| `/vms/{vmId}/start` | POST | Start VM | `vms::start_vm()` |
| `/vms/{vmId}/stop` | POST | Stop VM | `vms::stop_vm()` |
| `/vms/{vmId}/reset` | POST | Reset VM | `vms::reset_vm()` |
| `/vms/{vmId}/reboot` | POST | Reboot VM | `vms::reboot_vm()` |
| `/vms/{vmId}/ssh` | GET | Get SSH command | `vms::get_ssh_command()` |

### 4.3 Container Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/vms/{vmId}/containers/{name}/start` | POST | Start container | `containers::start()` |
| `/vms/{vmId}/containers/{name}/stop` | POST | Stop container | `containers::stop()` |
| `/vms/{vmId}/containers/{name}/restart` | POST | Restart container | `containers::restart()` |
| `/vms/{vmId}/containers/{name}/logs` | GET | Get container logs | `containers::logs()` |

### 4.4 Service Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/services` | GET | List all services | `services::list_services()` |
| `/services/{svcId}` | GET | Get service info | `services::get_service()` |
| `/services/{svcId}/status` | GET | Get service status | `services::get_service_status()` |
| `/services/{svcId}/health` | GET | Health check | `services::get_service_health()` |
| `/services/{svcId}/containers` | GET | List containers | `services::get_containers()` |
| `/services/{svcId}/restart` | POST | Restart service | `services::restart()` |
| `/services/{svcId}/logs` | GET | Get logs | `services::logs()` |

### 4.5 Domain Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/domains` | GET | List all domains | `domains::list_domains()` |
| `/domains/{domain}` | GET | Get domain config | `domains::get_domain()` |
| `/domains/{domain}/status` | GET | Check domain status | `domains::check_status()` |
| `/domains/{domain}/ssl` | GET | Get SSL certificate info | `domains::get_ssl_info()` |

### 4.6 Topology Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/topology` | GET | Full topology graph | `topology::full()` |
| `/topology/vms` | GET | VM topology | `topology::vms()` |
| `/topology/services-by-vm` | GET | Services grouped by VM | `topology::services_by_vm()` |
| `/topology/containers` | GET | Container topology | `topology::containers()` |
| `/topology/networks` | GET | Network topology | `topology::networks()` |

### 4.7 Cost Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/cost` | GET | Full cost overview | `cost::overview()` |
| `/cost/summary` | GET | Cost summary | `cost::summary()` |
| `/cost/breakdown` | GET | Detailed breakdown | `cost::breakdown()` |
| `/cost/infra` | GET | Infrastructure costs | `cost::infra()` |
| `/cost/ai` | GET | AI service costs | `cost::ai()` |

### 4.8 Monitor Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/monitor` | GET | Full monitoring data | `monitor::full()` |
| `/monitor/summary` | GET | Quick summary | `monitor::summary()` |
| `/monitor/vms` | GET | VM metrics | `monitor::vms()` |
| `/monitor/endpoints` | GET | Endpoint status | `monitor::endpoints()` |
| `/monitor/containers` | GET | Container metrics | `monitor::containers()` |

### 4.9 Wake Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/wake/trigger` | POST | Trigger wake | `wake::trigger()` |
| `/wake/status` | GET | Wake status | `wake::status()` |

### 4.10 Dashboard Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/dashboard/summary` | GET | Full dashboard summary | `dashboard::summary()` |
| `/dashboard/quick-status` | GET | Quick status | `dashboard::quick_status()` |

### 4.11 Action Endpoints

| Endpoint | Method | Description | Implementation |
|----------|--------|-------------|----------------|
| `/actions/refresh-all` | POST | Refresh all caches | `actions::refresh_all()` |
| `/actions/generate-md` | POST | Generate MD report | `actions::generate_md()` |
| `/actions/backup` | POST | Trigger backup | `actions::backup()` |

---

## 5. Library API Design

### 5.1 Health Module

```rust
// health/external.rs - No SSH required
pub async fn ping(ip: &str, samples: u32) -> Result<PingResult>;
pub async fn ping_all(vms: &[Vm]) -> Result<Vec<(Vm, PingResult)>>;
pub async fn check_http(url: &str) -> Result<HttpResult>;
pub async fn check_http_all(endpoints: &[Endpoint]) -> Result<Vec<HttpResult>>;
pub async fn check_ssl(domain: &str) -> Result<SslResult>;
pub async fn check_ssl_all(domains: &[&str]) -> Result<Vec<SslResult>>;
pub async fn check_dns(domain: &str, expected: Option<&str>) -> Result<DnsResult>;
pub async fn check_port(ip: &str, port: u16) -> Result<PortResult>;

// health/internal.rs - Via SSH
pub async fn check_docker(vm: &Vm) -> Result<DockerStatus>;
pub async fn check_container(vm: &Vm, container: &str) -> Result<ContainerStatus>;
pub async fn check_disk(vm: &Vm) -> Result<Vec<DiskStatus>>;
pub async fn check_memory(vm: &Vm) -> Result<MemoryStatus>;
pub async fn check_load(vm: &Vm) -> Result<LoadStatus>;
pub async fn get_system_info(vm: &Vm) -> Result<SystemStatus>;
pub async fn get_recent_logs(vm: &Vm, lines: u32) -> Result<Vec<LogEntry>>;

// health/report.rs
pub async fn generate_report(vms: &[Vm], config: &HealthConfig) -> Result<HealthReport>;
pub async fn generate_external_report(vms: &[Vm]) -> Result<HealthReport>;
pub async fn generate_internal_report(vms: &[Vm]) -> Result<HealthReport>;
pub fn analyze_issues(report: &HealthReport) -> Vec<HealthIssue>;

// health/export.rs
pub fn export_json(report: &HealthReport, path: &Path) -> Result<()>;
pub fn export_markdown(report: &HealthReport, path: &Path) -> Result<()>;
pub fn export_all(report: &HealthReport, dir: &Path) -> Result<ExportPaths>;
```

### 5.2 VMs Module

```rust
// vms/registry.rs
pub fn list_vms() -> Vec<&Vm>;
pub fn get_vm(id: &str) -> Result<&Vm>;
pub fn list_vms_by_provider(provider: Provider) -> Vec<&Vm>;
pub fn list_vms_by_availability(availability: Availability) -> Vec<&Vm>;

// vms/status.rs
pub async fn get_vm_status(vm: &Vm) -> Result<VmStatus>;
pub async fn get_vm_status_all() -> Result<Vec<(Vm, VmStatus)>>;
pub async fn get_vm_details(vm: &Vm) -> Result<VmDetails>;
pub async fn get_vm_ram_percent(vm: &Vm) -> Result<Option<u8>>;

// vms/control.rs
pub async fn start_vm(vm: &Vm) -> Result<()>;
pub async fn stop_vm(vm: &Vm) -> Result<()>;
pub async fn reset_vm(vm: &Vm) -> Result<()>;
pub async fn reboot_vm(vm: &Vm) -> Result<()>;
pub fn get_ssh_command(vm: &Vm) -> String;
```

### 5.3 Services Module

```rust
// services/registry.rs
pub fn list_services() -> Vec<&Service>;
pub fn get_service(id: &str) -> Result<&Service>;
pub fn list_services_by_vm(vm_id: &str) -> Vec<&Service>;
pub fn list_services_by_category(category: &str) -> Vec<&Service>;

// services/status.rs
pub async fn get_service_status(svc: &Service) -> Result<ServiceStatus>;
pub async fn get_service_health(svc: &Service) -> Result<ServiceHealth>;
pub async fn get_service_containers(svc: &Service) -> Result<Vec<Container>>;
```

### 5.4 Containers Module

```rust
// containers/list.rs
pub async fn list_containers(vm: &Vm) -> Result<Vec<Container>>;
pub async fn get_container(vm: &Vm, name: &str) -> Result<Container>;

// containers/control.rs
pub async fn start_container(vm: &Vm, name: &str) -> Result<()>;
pub async fn stop_container(vm: &Vm, name: &str) -> Result<()>;
pub async fn restart_container(vm: &Vm, name: &str) -> Result<()>;
pub async fn get_container_logs(vm: &Vm, name: &str, lines: u32) -> Result<String>;
```

### 5.5 Domains Module

```rust
// domains/registry.rs
pub fn list_domains() -> Vec<&Domain>;
pub fn get_domain(name: &str) -> Result<&Domain>;

// domains/status.rs
pub async fn check_domain_status(domain: &Domain) -> Result<DomainStatus>;
pub async fn check_domain_dns(domain: &Domain) -> Result<DnsResult>;

// domains/ssl.rs
pub async fn check_ssl(domain: &str) -> Result<SslResult>;
pub async fn get_ssl_info(domain: &str) -> Result<SslInfo>;
pub async fn get_expiring_certs(days: u32) -> Result<Vec<SslResult>>;
```

### 5.6 Topology Module

```rust
// topology/vms.rs
pub fn vm_topology() -> TopologyGraph;

// topology/services.rs
pub fn services_by_vm() -> HashMap<String, Vec<Service>>;
pub fn services_topology() -> TopologyGraph;

// topology/containers.rs
pub async fn container_topology() -> Result<TopologyGraph>;

// topology/networks.rs
pub fn network_topology() -> TopologyGraph;
```

### 5.7 Cost Module

```rust
// cost/infra.rs
pub fn infrastructure_cost() -> CostBreakdown;
pub fn cost_by_provider() -> HashMap<Provider, CostSummary>;
pub fn cost_by_vm() -> HashMap<String, CostSummary>;

// cost/ai.rs
pub fn ai_cost() -> CostBreakdown;
pub fn claude_cost() -> CostSummary;
```

### 5.8 Wake Module

```rust
// wake/trigger.rs
pub async fn trigger_wake(vm: &Vm) -> Result<WakeResult>;
pub async fn trigger_wake_by_id(vm_id: &str) -> Result<WakeResult>;

// wake/status.rs
pub async fn wake_status(vm: &Vm) -> Result<WakeStatus>;
pub async fn wake_poll(vm: &Vm, timeout_secs: u32) -> Result<WakeStatus>;
```

---

## 6. Data Types

### 6.1 Health Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthReport {
    pub timestamp: DateTime<Utc>,
    pub duration_ms: u64,
    pub vms: Vec<VmHealthReport>,
    pub summary: HealthSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmHealthReport {
    pub vm: VmInfo,
    pub external: ExternalChecks,
    pub internal: Option<InternalChecks>,
    pub overall_status: HealthStatus,
    pub issues: Vec<HealthIssue>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalChecks {
    pub ping: PingResult,
    pub http_endpoints: Vec<HttpResult>,
    pub ssl_certs: Vec<SslResult>,
    pub dns_records: Vec<DnsResult>,
    pub port_checks: Vec<PortResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InternalChecks {
    pub ssh_connected: bool,
    pub docker: DockerStatus,
    pub system: SystemStatus,
    pub services: Vec<ServiceStatus>,
    pub logs: LogSummary,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum HealthStatus {
    Healthy,
    Degraded,
    Unhealthy,
    Unknown,
}
```

### 6.2 VM Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Vm {
    pub id: String,
    pub name: String,
    pub display_name: String,
    pub provider: Provider,
    pub category: VmCategory,
    pub instance_type: String,
    pub specs: VmSpecs,
    pub network: VmNetwork,
    pub ssh: SshConfig,
    pub availability: Availability,
    pub cost: Option<CostInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmStatus {
    pub status: HealthStatus,
    pub label: String,
    pub ping: bool,
    pub ssh: bool,
    pub ram_percent: Option<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmDetails {
    pub hostname: String,
    pub uptime: String,
    pub kernel: String,
    pub cpu: u32,
    pub ram_used: String,
    pub ram_total: String,
    pub ram_percent: f64,
    pub disk_used: String,
    pub disk_total: String,
    pub containers: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum Provider {
    Oracle,
    Gcloud,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum Availability {
    AlwaysOn,      // 24/7
    WakeOnDemand,  // Wake when needed
}
```

### 6.3 Service Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Service {
    pub id: String,
    pub display_name: String,
    pub category: String,
    pub vm_id: String,
    pub containers: Vec<String>,
    pub technology: ServiceTechnology,
    pub urls: ServiceUrls,
    pub auth_required: bool,
    pub status: ServiceLifecycle,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceStatus {
    pub status: HealthStatus,
    pub label: String,
    pub healthy: Option<bool>,
    pub response_time_ms: Option<u64>,
}
```

### 6.4 Domain Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Domain {
    pub name: String,
    pub service: String,
    pub vm_id: String,
    pub proxy_via: Option<String>,
    pub ssl: bool,
    pub auth: DomainAuth,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SslResult {
    pub domain: String,
    pub status: HealthStatus,
    pub issuer: Option<String>,
    pub valid_from: Option<DateTime<Utc>>,
    pub valid_until: Option<DateTime<Utc>>,
    pub days_until_expiry: Option<i64>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum DomainAuth {
    None,
    Authelia,
    Native,
}
```

### 6.5 Topology Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopologyGraph {
    pub nodes: Vec<TopologyNode>,
    pub edges: Vec<TopologyEdge>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopologyNode {
    pub id: String,
    pub label: String,
    pub node_type: NodeType,
    pub metadata: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopologyEdge {
    pub source: String,
    pub target: String,
    pub edge_type: EdgeType,
}
```

### 6.6 Cost Types

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostSummary {
    pub total: f64,
    pub currency: String,
    pub period: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostBreakdown {
    pub summary: CostSummary,
    pub by_provider: HashMap<Provider, f64>,
    pub by_category: HashMap<String, f64>,
    pub items: Vec<CostItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostItem {
    pub name: String,
    pub category: String,
    pub amount: f64,
    pub notes: Option<String>,
}
```

---

## 7. CLI Interface

### Global Options

```
cloud-control [OPTIONS] <COMMAND>

OPTIONS:
    -v, --verbose       Verbose output
    -q, --quiet         Minimal output
    -c, --config <FILE> Config file path
    --json              JSON output (for scripting)
    -h, --help          Show help
    -V, --version       Show version
```

### Full Command Tree

```
cloud-control
|-- health
|   |-- [<vm>]                              # Quick status
|   |-- external [ping|http|ssl|dns|ports]  # External checks
|   |-- internal [<vm>] [docker|disk|memory|logs]
|   |-- full [--watch] [--parallel]
|   |-- debug <vm> [--logs|--shell]
|   +-- export [--format json|md] [--output <dir>]
|
|-- vms
|   |-- list [--provider <p>] [--status <s>]
|   |-- <vmId>                              # VM details
|   |-- <vmId> status
|   |-- <vmId> containers
|   |-- <vmId> start
|   |-- <vmId> stop
|   |-- <vmId> reset
|   +-- <vmId> ssh                          # Print SSH command
|
|-- services
|   |-- list [--vm <vmId>] [--category <c>]
|   |-- <svcId>                             # Service details
|   +-- <svcId> status
|
|-- containers
|   |-- list <vmId>
|   |-- <vmId> <name> start
|   |-- <vmId> <name> stop
|   |-- <vmId> <name> restart
|   +-- <vmId> <name> logs [--lines <n>]
|
|-- domains
|   |-- list
|   |-- <domain>                            # Domain details
|   |-- <domain> status
|   +-- <domain> ssl
|
|-- topology
|   |-- vms
|   |-- services
|   |-- containers
|   +-- networks
|
|-- cost
|   |-- summary
|   |-- breakdown
|   |-- infra
|   +-- ai
|
|-- monitor
|   |-- summary
|   |-- vms [--watch]
|   |-- endpoints
|   +-- containers
|
|-- wake
|   |-- <vmId>                              # Trigger wake
|   +-- status <vmId>
|
|-- export
|   |-- health [--format json|md]
|   |-- topology [--format json|svg]
|   +-- cost [--format json|csv]
|
+-- status                                  # Quick overall status
```

---

## 8. Terminal Output Examples

### Quick Status

```
+----------------------------------------------------------------+
|                    CLOUD CONTROL STATUS                         |
+----------------------------------------------------------------+
|  VM              STATUS      PING     CONTAINERS    DISK        |
+----------------------------------------------------------------+
|  GCP Hub         * Healthy   45ms     4/4 running   45%         |
|  OCI Flex        o Degraded  120ms    3/3 running   82%  !      |
|  OCI Mail        * Healthy   95ms     5/5 running   38%         |
|  OCI Analytics   * Healthy   92ms     2/2 running   25%         |
+----------------------------------------------------------------+

! 1 warning: OCI Flex disk usage at 82%
```

### Health Export (Markdown)

```markdown
# Cloud Health Report

**Generated:** 2025-12-30 14:30:00 UTC
**Duration:** 12.34s

## Summary

| Status | Count |
|--------|-------|
| Healthy | 3 |
| Degraded | 1 |
| Unhealthy | 0 |
| Unreachable | 0 |

---

## GCP Hub (gcp)

**Provider:** Google Cloud
**IP:** 34.55.55.234
**Status:** Healthy

### External Checks

| Check | Status | Details |
|-------|--------|---------|
| Ping | Healthy | 45.2ms (0% loss) |
| HTTP proxy.diegonmarcos.com | Healthy | 200 OK (234ms) |
| SSL proxy.diegonmarcos.com | Healthy | Valid 67 days |

### Internal Checks

**System:**
- Uptime: 12 days
- Load: 0.15 / 0.20 / 0.18
- Memory: 60% (0.6/1.0 GB)
- Disk: 45% (13.5/30 GB)

**Docker Containers:**

| Container | Status | Health | Uptime | Memory |
|-----------|--------|--------|--------|--------|
| npm | running | healthy | 5 days | 128MB |
| authelia | running | healthy | 5 days | 64MB |
```

---

## 9. Configuration

### 9.1 Architecture JSON (Source of Truth)

Location: `/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_architecture.json`

The library reads infrastructure definitions from this file.

### 9.2 Application Config

Location: `~/.config/cloud-control/config.toml`

```toml
[general]
verbose = false
architecture_path = "~/Documents/Git/back-System/cloud/1.ops/cloud_architecture.json"

[health]
ping_samples = 10
ping_timeout_ms = 1000
http_timeout_ms = 5000
ssh_timeout_ms = 10000
ssl_expiry_warning_days = 30
disk_usage_warning_percent = 80

[health.export]
dir = "~/Documents/exports/cloud/health"
keep_history_days = 30

[api]
host = "0.0.0.0"
port = 5000
cors_origins = ["https://diegonmarcos.com", "http://localhost:8006"]

[api.auth]
enabled = true
oidc_issuer = "https://auth.diegonmarcos.com"
```

---

## 10. Migration from Python

### 10.1 Endpoint Mapping

| Python Function | Rust Function |
|-----------------|---------------|
| `routes.py:health_check()` | `health::ping()` |
| `routes.py:list_vms()` | `vms::list_vms()` |
| `routes.py:get_vm_info()` | `vms::get_vm()` |
| `routes.py:get_vm_health()` | `vms::get_vm_status()` |
| `routes.py:get_vm_remote_details()` | `vms::get_vm_details()` |
| `routes.py:get_vm_containers()` | `containers::list_containers()` |
| `routes.py:start_vm()` | `vms::start_vm()` |
| `routes.py:stop_vm()` | `vms::stop_vm()` |
| `routes.py:reset_vm()` | `vms::reset_vm()` |
| `routes.py:restart_container()` | `containers::restart_container()` |
| `routes.py:list_services()` | `services::list_services()` |
| `routes.py:get_service_info()` | `services::get_service()` |
| `routes.py:get_service_health()` | `services::get_service_status()` |
| `routes.py:list_domains()` | `domains::list_domains()` |
| `routes.py:get_dashboard_summary()` | `dashboard::summary()` |
| `routes.py:trigger_wake()` | `wake::trigger_wake()` |
| `health.py:check_ping()` | `health::ping()` |
| `health.py:check_ssh()` | `ssh::connect()` |
| `health.py:check_http()` | `health::check_http()` |
| `health.py:get_vm_status()` | `vms::get_vm_status()` |
| `health.py:get_container_status()` | `containers::list_containers()` |

### 10.2 Migration Phases

**Phase 1:** Core library with read-only functions
- VMs registry, Services registry, Domains registry
- External health checks (ping, HTTP, SSL, DNS)

**Phase 2:** SSH-based operations
- Internal health checks
- VM details via SSH
- Container listing

**Phase 3:** Control operations
- VM start/stop/reset
- Container start/stop/restart
- Wake-on-demand

**Phase 4:** Aggregation endpoints
- Dashboard summary
- Topology generation
- Cost calculations

**Phase 5:** API server
- Axum routes
- Authentication middleware
- CORS configuration

**Phase 6:** CLI tool
- All commands implemented
- JSON output support
- Table formatting

---

## 11. Implementation Phases

### Phase 1: Core Foundation
- [ ] Project structure
- [ ] Config loader
- [ ] Architecture JSON parser
- [ ] Error handling

### Phase 2: VMs Module
- [ ] VM registry (from architecture.json)
- [ ] VM status checks
- [ ] VM details via SSH
- [ ] VM control (start/stop/reset)

### Phase 3: Health Module
- [ ] External checks (ping, HTTP, SSL, DNS, ports)
- [ ] Internal checks via SSH
- [ ] Report generation
- [ ] Export (JSON + MD)

### Phase 4: Services & Containers
- [ ] Service registry
- [ ] Service status
- [ ] Container listing
- [ ] Container control

### Phase 5: Domains & Topology
- [ ] Domain registry
- [ ] Domain status & SSL checks
- [ ] Topology generation

### Phase 6: Cost & Monitor
- [ ] Cost calculations
- [ ] Monitoring endpoints

### Phase 7: Wake-on-Demand
- [ ] Wake trigger (OCI API)
- [ ] Wake status polling

### Phase 8: API Server
- [ ] Axum routes
- [ ] Authentication
- [ ] CORS

### Phase 9: CLI
- [ ] All commands
- [ ] Output formatting

---

## 12. Dependencies

### Cargo.toml (Workspace)

```toml
[workspace]
resolver = "2"
members = [
    "crates/control_lib",
    "crates/control_cli",
    "crates/control_api",
]

[workspace.dependencies]
tokio = { version = "1", features = ["full", "process"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
reqwest = { version = "0.12", features = ["json", "rustls-tls"] }
chrono = { version = "0.4", features = ["serde"] }
anyhow = "1"
thiserror = "2"
dirs = "6"
```

### control_lib

```toml
[dependencies]
tokio.workspace = true
serde.workspace = true
serde_json.workspace = true
chrono.workspace = true
anyhow.workspace = true
thiserror.workspace = true
reqwest.workspace = true
dirs.workspace = true

# SSH
russh = "0.45"
russh-keys = "0.45"

# Ping
surge-ping = "0.8"

# SSL inspection
x509-parser = "0.16"
rustls = "0.23"

# DNS
trust-dns-resolver = "0.24"
```

### control_api

```toml
[dependencies]
control_lib = { path = "../control_lib" }
tokio.workspace = true
serde.workspace = true
serde_json.workspace = true
anyhow.workspace = true

# Web framework
axum = { version = "0.7", features = ["macros"] }
tower = "0.5"
tower-http = { version = "0.6", features = ["cors", "trace"] }

# Logging
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
```

### control_cli

```toml
[dependencies]
control_lib = { path = "../control_lib" }
tokio.workspace = true
serde.workspace = true
serde_json.workspace = true
anyhow.workspace = true

# CLI
clap = { version = "4", features = ["derive", "cargo", "env"] }

# Terminal UI
tabled = "0.17"
owo-colors = "4"
indicatif = "0.17"
console = "0.15"
```

---

## 13. Related Projects

- **Cloud Connect**: Portable secure workstation bootstrapper
  - Location: `back-System/cloud/a_solutions/front-apps/cloud_connect/`
  - See: `CLOUD_CONNECT.md`

- **Web Dashboard**: cloud_control.html
  - Location: `front-Github_io/a_Cloud/cloud/src_vanilla/cloud_control.html`

- **Python API** (to be replaced):
  - Location: `back-System/cloud/a_solutions/back-data_know_center/0_api/`
