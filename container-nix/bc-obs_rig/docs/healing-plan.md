# Rig Intelligence Framework - Master Plan

**Project**: Rig-based Autonomous Cloud Intelligence System
**Target**: oci-apps (3 vCPU, 16GB, aarch64)
**Purpose**: Self-healing infrastructure + GraphRAG + Agentic AI orchestration
**Status**: Revised after Opus review
**Created**: 2026-02-16

---

## Vision

Transform cloud infrastructure from "Infrastructure as Code" to **"Infrastructure as Intelligence"** using:
- **Rig** (Rust) as the orchestration framework
- **SurrealDB** as the Hybrid Knowledge Graph (Vector + Graph)
- **Ollama 14B** (via vast.ai, ephemeral GPU rental) as the reasoning engine
- **LightRAG** for incremental KG maintenance

No local CPU/RAM Ollama fallback. If vast.ai is down, AI-dependent workflows gracefully degrade: skip AI reasoning, send ntfy alert to human.

---

## Architecture Overview

```
+--------------------------------------------------------------------+
|  oci-apps (3 vCPU, 16GB, aarch64) - "The Brain"                   |
|                                                                     |
|  +--------------------------------------------------------------+  |
|  |  RIG ORCHESTRATOR (bc-obs_rig)                         :8090  |  |
|  |                                                               |  |
|  |  Macro Workflow 1: Self-Backups                                |  |
|  |   +-- VolumeSnapshotOp (tar + compress Docker volumes)        |  |
|  |   +-- DatabaseDumpOp (SurrealDB, PostgreSQL, MariaDB)         |  |
|  |   +-- RotationOp (7 daily, 4 weekly, 3 monthly)              |  |
|  |   +-- RemoteSyncOp (rsync to oci-apps-1)                     |  |
|  |   +-- VerifyBackupOp (restore to temp container)              |  |
|  |                                                               |  |
|  |  Macro Workflow 2: Self-Healing                               |  |
|  |   +-- HealthCheckOp (non-AI, fast)                            |  |
|  |   +-- SmartMaintenanceOp (AI when needed)                     |  |
|  |   +-- SelfHealingOp (sandboxed execution)                     |  |
|  |   +-- WebhookOp (ntfy notifications)                          |  |
|  |                                                               |  |
|  |  Macro Workflow 3: Self-Protection                            |  |
|  |   +-- AuthLogMonitorOp (failed SSH → auto-ban)               |  |
|  |   +-- DockerAuditOp (unexpected containers → alert)          |  |
|  |   +-- CertExpiryOp (TLS cert monitoring)                     |  |
|  |   +-- DriftDetectionOp (running vs declared state)            |  |
|  |                                                               |  |
|  |  Macro Workflow 4: KG Maintenance                             |  |
|  |   +-- DailyIndexOp (embeddings via vast.ai Ollama)            |  |
|  |   +-- WeeklyReviewOp (Opus via API)                           |  |
|  |   +-- IncrementalSyncOp (LightRAG)                            |  |
|  |   +-- GraphPruneOp (remove stale nodes)                       |  |
|  |                                                               |  |
|  |  Macro Workflow 5: Agentic Framework (API Gateway)            |  |
|  |   +-- KG Query API (MCP integration)                          |  |
|  |   +-- Ollama Proxy (vast.ai connection)                       |  |
|  |   +-- Multi-Agent Orchestration                               |  |
|  |   +-- Tool Execution (SSH, Docker, git)                       |  |
|  |                                                               |  |
|  |  Internal: kg/embeddings.rs (HTTP client to vast.ai           |  |
|  |            Ollama /v1/embeddings - no separate service)        |  |
|  +--------------------------------------------------------------+  |
|                              ^ v                                    |
|  +--------------------------------------------------------------+  |
|  |  SURREALDB HYBRID KG (ca-dat_kg-graph)                :8001  |  |
|  |                                                               |  |
|  |  Graph Layer:                                                 |  |
|  |   +-- Nodes: vm, service, container, log, doc, alert         |  |
|  |   +-- Edges: hosted_on, depends_on, proxied_by, caused_by    |  |
|  |   +-- Schema: Typed relationships, temporal data              |  |
|  |                                                               |  |
|  |  Vector Layer (embedded, no separate service):                |  |
|  |   +-- Embeddings: nomic-embed-text (768-dim)                 |  |
|  |   +-- Index: MTREE for fast similarity search                |  |
|  |   +-- Content: logs, docs, error messages, configs           |  |
|  +--------------------------------------------------------------+  |
|                              ^ v                                    |
|  +--------------------------------------------------------------+  |
|  |  LIGHTRAG SYNC (Rust, inside Rig binary)                      |  |
|  |   +-- Docker event listener (container lifecycle)             |  |
|  |   +-- Log file watcher (inotify)                              |  |
|  |   +-- Incremental embeddings (only changed nodes)             |  |
|  +--------------------------------------------------------------+  |
|                                                                     |
|  +--------------------------------------------------------------+  |
|  |  AUDIT LOG (dual-write)                                       |  |
|  |   +-- SurrealDB: structured audit entries                     |  |
|  |   +-- Local file: /opt/data/rig/audit.jsonl (append-only)     |  |
|  |   +-- If SurrealDB down, local file survives                  |  |
|  +--------------------------------------------------------------+  |
+--------------------------------------------------------------------+
                              ^ v  OpenAI-compatible API
+--------------------------------------------------------------------+
|  vast.ai GPU Instance (RTX A4000, 16GB VRAM) - On-Demand           |
|  EPHEMERAL: IP/port change on every rental                          |
|                                                                     |
|  +--------------------------------------------------------------+  |
|  |  OLLAMA 14B (Qwen 2.5)                                       |  |
|  |   +-- Model: qwen2.5:14b-instruct-q4_K_M                     |  |
|  |   +-- Endpoint: http://<dynamic-ip>:11434/v1                  |  |
|  |   +-- Context: 8192 tokens                                    |  |
|  |   +-- Cost: $0.08-0.25/hr (only when Rig needs reasoning)    |  |
|  +--------------------------------------------------------------+  |
|  +--------------------------------------------------------------+  |
|  |  OLLAMA EMBED (nomic-embed-text)                              |  |
|  |   +-- For generating 768-dim embeddings                       |  |
|  |   +-- Endpoint: http://<dynamic-ip>:11434/v1/embeddings       |  |
|  +--------------------------------------------------------------+  |
+--------------------------------------------------------------------+
                              ^
                   SSH tunnel from oci-apps
```

---

## Component Breakdown

### 1. bc-obs_rig (Rig Orchestrator)

**Path**: `~/git/cloud/a_solutions/container-nix/bc-obs_rig/`

**Purpose**: Central nervous system for infrastructure intelligence. Also contains all embedding logic (simple HTTP client to vast.ai Ollama's `/v1/embeddings` endpoint). No separate embedding service.

**Structure**:
```
bc-obs_rig/
├── src/
│   ├── main.rs                    # Main event loop + HTTP server + tokio scheduler
│   ├── config.rs                  # Configuration (KG URL, vast.ai dynamic endpoint, SSH keys)
│   ├── workflows/
│   │   ├── mod.rs
│   │   ├── self_backups.rs        # Macro Workflow 1: Backup lifecycle
│   │   ├── self_healing.rs        # Macro Workflow 2: Detect + recover
│   │   ├── self_protection.rs     # Macro Workflow 3: Monitor + defend
│   │   ├── kg_maintenance.rs      # Macro Workflow 4: KG curation
│   │   └── agentic_framework.rs   # Macro Workflow 5: Agent gateway
│   ├── ops/
│   │   ├── mod.rs
│   │   ├── volume_snapshot.rs     # Backup: tar + compress volumes
│   │   ├── database_dump.rs       # Backup: SurrealDB/PG/MariaDB exports
│   │   ├── backup_rotation.rs     # Backup: prune old (7d/4w/3m)
│   │   ├── backup_sync.rs         # Backup: rsync to oci-apps-1
│   │   ├── backup_verify.rs       # Backup: restore to temp container
│   │   ├── health_check.rs        # Healing: fast non-AI checks
│   │   ├── smart_maintenance.rs   # Healing: conditional AI invocation
│   │   ├── self_healing.rs        # Healing: sandboxed command execution
│   │   ├── auth_log_monitor.rs    # Protection: SSH fail2ban
│   │   ├── docker_audit.rs        # Protection: unexpected containers
│   │   ├── cert_expiry.rs         # Protection: TLS cert monitoring
│   │   ├── drift_detection.rs     # Protection: running vs declared
│   │   ├── webhook.rs             # ntfy notifications
│   │   ├── daily_index.rs         # KG daily maintenance
│   │   ├── weekly_review.rs       # Opus-powered analysis
│   │   ├── incremental_sync.rs    # LightRAG integration
│   │   └── vast_ai_provider.rs   # vast.ai instance management + SSH tunnel
│   ├── kg/
│   │   ├── mod.rs
│   │   ├── client.rs              # SurrealDB client wrapper
│   │   ├── queries.rs             # Hybrid search, blast radius, etc.
│   │   ├── schema.rs              # Rust types for KG entities
│   │   └── embeddings.rs          # HTTP client to vast.ai Ollama /v1/embeddings
│   ├── agents/
│   │   ├── mod.rs
│   │   ├── ollama_client.rs       # OpenAI-compatible client for vast.ai Ollama
│   │   ├── mcp_server.rs          # Embedded MCP server (optional)
│   │   └── tool_executor.rs       # SSH/Docker/Git execution with guardrails
│   ├── audit.rs                   # Dual-write audit: SurrealDB + local append-only file
│   └── lib.rs
├── Cargo.toml
├── build.sh                       # Universal build engine
├── build.json                     # Deploy to oci-apps
└── docs/
    ├── healing-plan.md            # This document
    ├── API.md                     # REST API documentation
    └── WORKFLOWS.md               # Detailed workflow logic
```

**Key Dependencies**:
```toml
[dependencies]
rig-core = "0.3"                   # Rig framework
surrealdb = "2.0"                  # KG client
tokio = { version = "1", features = ["full"] }
axum = "0.7"                       # HTTP server for API
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.12", features = ["json"] }
notify = "6"                       # File system watcher
bollard = "0.17"                   # Docker API client
russh = "0.46"                     # Pure-Rust SSH (no libssh2 C dep)
tracing = "0.1"                    # Structured logging
```

**Note on SSH**: The `ssh2` crate wraps libssh2 (C library) which is painful to cross-compile for aarch64. Use `russh` (pure Rust) or fall back to `tokio::process::Command` shelling out to the system `ssh` binary, since SSH keys and configs are already set up on all VMs.

**Deployment**:
- **Target**: oci-apps (aarch64)
- **Build**: On-machine (via build.sh ship pattern)
- **Runtime**: systemd service, auto-restart
- **Port**: 8090 (NOT 8080 -- the existing Rust API uses 8080 on gcp-proxy)
- **External access**: Caddy reverse proxy at `api.diegonmarcos.com/rig/` via WireGuard

**Caddy config update required** (gcp-proxy): Add a new `handle /rig/*` block in the Caddyfile routing to `10.0.0.6:8090` over WireGuard. This is an explicit Phase 2 task.

**Scheduling**: All periodic tasks (health checks every 5 min, daily indexing at 3 AM, weekly review Sunday 2 AM) use `tokio::time::interval` inside the Rig binary. No external cron dependency.

---

### 2. ca-dat_kg-graph (SurrealDB Hybrid KG)

**Path**: `~/git/cloud/a_solutions/container-nix/ca-dat_kg-graph/`

**Purpose**: Store infrastructure topology, relationships, temporal state, AND vector embeddings. The vector layer lives inside SurrealDB (MTREE index on `embedding` fields). There is no separate vector service.

**Structure**:
```
ca-dat_kg-graph/
├── src/
│   ├── flake.nix                  # Nix flake (generates docker-compose.yml)
│   ├── schema.surql               # SurrealDB schema definitions
│   ├── seed.surql                 # Initial data from architecture.json
│   └── queries/
│       ├── blast_radius.surql     # Pre-defined graph queries
│       ├── dependency_chain.surql
│       └── similar_incidents.surql
├── scripts/
│   ├── seed_from_config.sh        # Automated: parses Caddyfile, Authelia, Compose, WireGuard
│   └── verify_schema.sh           # Health check
├── build.sh
└── build.json                     # Deploy to oci-apps
```

**Schema Entities**:
- **Nodes**: vm, service, container, log, documentation, alert
- **Edges**: hosted_on, depends_on, proxied_by, authenticated_by, caused_by, similar_to, connected_to

**Automated Dependency Inference** (seed script):
Instead of manually writing 100+ RELATE statements, the seed script infers edges from existing configs:

| Source | Parsing target | Generated edge |
|--------|---------------|----------------|
| Caddyfile | `reverse_proxy` targets | `proxied_by` (service -> caddy) |
| Authelia config | Protected domains | `authenticated_by` (service -> authelia) |
| Docker Compose files | `depends_on` + shared networks | `depends_on` (service -> service) |
| WireGuard configs | VM-to-VM connectivity | `connected_to` (vm -> vm) |
| architecture.json / config.json | VM + service mappings | `hosted_on` (service -> vm) |

**Storage**:
- **Location**: `/opt/data/surrealdb/` on oci-apps
- **Persistence**: Btrfs subvolume
- **Backup**: Configure SurrealDB data directory for borg/bup backup to oci-apps-1 (where existing backup-borg and backup-bup services run). Explicit task in Phase 1.
- **Size estimate**: ~500MB for 5 VMs, 44 services, 30 days of logs

**Access**:
- **Internal**: `http://localhost:8001` (oci-apps only)
- **External**: Via Rig API proxy (no direct access)

---

### 3. ca-dat_kg-vector -- ELIMINATED

The `ca-dat_kg-vector` folder should be **deleted**. There is no separate embedding service. All embedding generation is handled by `bc-obs_rig/src/kg/embeddings.rs`, which is a simple HTTP client calling vast.ai Ollama's `/v1/embeddings` endpoint:

```rust
// bc-obs_rig/src/kg/embeddings.rs (simplified)
pub async fn generate_embeddings(
    client: &reqwest::Client,
    ollama_url: &str, // Dynamic, from VastAiProviderOp
    texts: &[String],
) -> Result<Vec<Vec<f32>>> {
    let resp = client.post(format!("{}/v1/embeddings", ollama_url))
        .json(&serde_json::json!({
            "model": "nomic-embed-text",
            "input": texts
        }))
        .send()
        .await?;
    // Parse OpenAI-compatible response
    let body: EmbeddingResponse = resp.json().await?;
    Ok(body.data.into_iter().map(|e| e.embedding).collect())
}
```

Results are inserted into SurrealDB `embedding` fields and indexed via MTREE.

---

### 4. Integration with Existing Components

#### 4.1 MCP Server (bb-sec_mcp-server-skills)

**Add new tools**:
```typescript
// src/tools/kg.ts
- kg_hybrid_search(query, search_type, traverse_depth)
- kg_blast_radius(entity_type, entity_id)
- kg_find_similar_incidents(error_message, time_range)
- kg_get_dependencies(service_name, depth)
- kg_query_raw(surql_query)  // Power users
```

**Add new resource**:
```typescript
cloud://kg/infrastructure-graph  // Live KG snapshot
cloud://kg/recent-incidents      // Last 7 days of issues
```

#### 4.2 Vast.ai (b_infra/vm_vast-RTX-p_0)

**Current state**: Manual SSH, Ollama pre-installed. Instances are **ephemeral** -- IP and port change on every rental.

**VastAiProviderOp** (Phase 0 work):
1. Checks vast.ai REST API for running instances
2. If an instance is up: establishes SSH tunnel, marks Ollama endpoint as available, updates dynamic config
3. If no instance running: marks AI features as degraded, sends ntfy alert "vast.ai offline, AI features degraded"
4. All AI-dependent operations check this status before attempting inference and skip gracefully if unavailable

**Cost optimization**:
- Rig only calls Ollama when `SmartMaintenanceOp` detects an anomaly
- Daily KG indexing uses vast.ai Ollama for embeddings (batch, fast)
- Weekly reviews use Opus API (higher quality, scheduled)
- Average: ~2 hrs/week = $0.50-1.00/week = **$2-4/month**

---

## Macro Workflow Specifications

### Workflow 1: Self-Backups

**Trigger**: `tokio::time::interval` daily at 2 AM, or manual API call

**Purpose**: Automated backup lifecycle — snapshot, dump, rotate, sync, verify. The most conservative workflow, deployed first because it's read-only (no mutations to running services) and provides immediate safety net.

**Pipeline**:
```rust
pipeline::new()
    .chain(VolumeSnapshotOp)             // tar + compress Docker volumes
    .chain(DatabaseDumpOp)               // SurrealDB export, pg_dump, mysqldump
    .chain(RotationOp)                   // Prune: keep 7 daily, 4 weekly, 3 monthly
    .chain(RemoteSyncOp)                 // rsync backups to oci-apps-1
    .chain(VerifyBackupOp)               // Restore to temp container, validate
    .chain(KgUpdateOp)                   // Record backup metadata in KG
    .chain(WebhookOp)                    // ntfy summary: "3 backups OK, 0 failed"
```

**Backup Targets** (per VM):

| VM | What | Method | Schedule |
|---|---|---|---|
| oci-apps | SurrealDB data | `surreal export` | Daily |
| oci-apps | Docker volumes (crawlee, rig) | `docker run --rm -v vol:/data alpine tar czf` | Daily |
| oci-apps-1 | PostgreSQL (NocoDB) | `pg_dump` via docker exec | Daily |
| oci-apps-1 | PhotoPrism originals index | Volume tar | Weekly |
| oci-mail | Mailu data (mail, certs) | Volume tar | Daily |
| oci-mail | Radicale calendars | Volume tar | Daily |
| oci-analytics | Matomo database (MariaDB) | `mysqldump` via docker exec | Daily |
| gcp-proxy | Authelia config + db | Volume tar | Daily |
| gcp-proxy | Vaultwarden data | Volume tar | Daily |

**Rotation Policy**:
```
/opt/data/backups/
├── daily/          # Last 7 days
├── weekly/         # Last 4 Sundays
└── monthly/        # Last 3 first-of-month
```

**Remote Redundancy**: After local rotation, `rsync --delete` daily/ and weekly/ to `oci-apps-1:/opt/data/backups-remote/oci-apps/` (oci-apps-1 has 193GB disk, only 34GB used).

**Verification**: Weekly, pick one random backup, restore to a temp Docker container, run a basic health check (e.g., SurrealDB: `surreal import` + count tables; PostgreSQL: `pg_restore` + count rows). Log pass/fail to KG.

**KG Tracking**:
```surql
CREATE backup_record CONTENT {
    timestamp: time::now(),
    vm: "oci-apps",
    target: "surrealdb",
    method: "surreal_export",
    size_bytes: 15234567,
    duration_secs: 12,
    local_path: "/opt/data/backups/daily/surrealdb-2026-02-17.gz",
    remote_synced: true,
    verified: null,  -- set by VerifyBackupOp
    status: "success"
};
```

---

### Workflow 2: Self-Healing

**Trigger**: `tokio::time::interval` every 5 minutes, or manual API call, or alert webhook

**Pipeline**:
```rust
// NOTE: Op trait signatures here are conceptual pseudocode.
// Actual Rig API surface to be validated in Phase 2 spike.
pipeline::new()
    .chain(HealthCheckOp)                // Fast check (CPU, disk, RAM, Docker)
    .chain(ConditionalOp::new(
        |status| status.is_healthy(),    // Predicate
        NoOp,                             // Happy path — nothing to do
        SmartMaintenanceOp                // Unhappy path (AI diagnosis)
    ))
    .chain(SelfHealingOp)                // Execute fix if diagnosis suggests one
    .chain(VerifyOp)                     // Re-check health after fix
    .chain(WebhookOp)                    // Notify user of outcome
```

**AI Invocation**:
- Only if: `disk > 90% OR memory > 95% OR error_log.is_some()`
- Checks `VastAiProviderOp` status first. If vast.ai is down, skips AI diagnosis and sends ntfy alert with raw health data for human review.
- Prompt includes: KG context (similar past issues), current system state, dependency graph
- Output: JSON with `{diagnosis, fix_command, risk_level, blast_radius}`

**Guardrails**:
```rust
struct HealingConstraints {
    allowed_commands: Vec<Regex>,  // rm /tmp/*, docker restart, systemctl reload
    forbidden_paths: Vec<&str>,    // /nix/store, /home, /etc/nixos
    dry_run_first: bool,           // Always simulate before execute
    max_retries: u8,               // Prevent infinite loops
    human_approval_threshold: RiskLevel,  // HIGH requires ntfy approval
}
```

**Example scenario**:
1. `HealthCheckOp` detects: `disk_usage_percent: 98`
2. `SmartMaintenanceOp` queries KG: "Similar issues in last 30 days?"
3. KG returns: "3 incidents on oci-analytics, all caused by Docker logs"
4. Ollama diagnosis: `{"fix": "docker system prune -af --volumes", "risk": "medium"}`
5. `SelfHealingOp` sends ntfy notification: "Disk 98%. Run docker prune? [Yes/No]"
6. User approves -> Execute -> Verify disk now at 45% -> Send success webhook

---

### Workflow 3: Self-Protection

**Trigger**: `tokio::time::interval` every 10 minutes, or manual API call

**Purpose**: Monitor and defend against threats. Purely observational by default — alerts via ntfy. Auto-remediation (e.g., iptables ban) only for well-defined, low-risk patterns.

**Pipeline**:
```rust
pipeline::new()
    .chain(AuthLogMonitorOp)             // Parse auth.log, detect brute force
    .chain(DockerAuditOp)                // Detect unexpected containers/images
    .chain(CertExpiryOp)                 // Check TLS cert expiry for all domains
    .chain(DriftDetectionOp)             // Compare running state vs KG declared
    .chain(PortScanDetectionOp)          // Monitor unexpected inbound via ss/conntrack
    .chain(KgUpdateOp)                   // Record findings in KG security_event table
    .chain(WebhookOp)                    // Alert on any findings
```

**Auth Log Monitor**:
- Parse `/var/log/auth.log` for failed SSH attempts
- Threshold: 5 failures from same IP in 10 minutes → auto-ban via `iptables -A INPUT -s <IP> -j DROP`
- Log banned IPs to KG `security_event` table
- ntfy alert: "Banned IP x.x.x.x (15 failed SSH attempts in 10 min)"

**Docker Socket Audit**:
- `docker ps` → compare running container names/images against KG `service` table
- Unknown container detected → HIGH alert via ntfy (do NOT auto-remove)
- Image hash mismatch (running vs declared) → MEDIUM alert

**Certificate Expiry Monitor**:
- Check TLS cert for all domains in KG (`*.diegonmarcos.com`)
- Alert thresholds: 30 days (info), 14 days (warning), 7 days (critical)
- Use `openssl s_client` or `reqwest` to fetch cert and parse `notAfter`

**Drift Detection**:
- Compare for each service: running Docker image tag vs KG declared version
- Compare container env vars vs expected (from docker-compose.yml in KG)
- Compare exposed ports vs declared
- Any mismatch → log to KG `drift_event` + ntfy alert

**OCI Security List Audit** (weekly):
- Query OCI API for current security list rules
- Compare against expected rules in KG
- Alert on unexpected open ports or missing rules

---

### Workflow 4: KG Maintenance

#### Daily Indexing (Automated, 3 AM via tokio scheduler)

**Purpose**: Keep KG fresh with yesterday's logs, deploys, container events

**Pipeline**:
```rust
pipeline::new()
    .chain(FetchNewLogsOp)               // Query journald, Docker logs since last run
    .chain(EmbedBatchOp)                 // Generate vectors (vast.ai Ollama)
    .chain(InsertKGOp)                   // Insert into SurrealDB
    .chain(UpdateRelationsOp)            // If new service deployed, add edges
    .chain(PruneStaleOp)                 // Remove logs > 30 days old
    .chain(CompactIndexOp)               // Optimize SurrealDB MTREE index
```

**Embedding**: Via vast.ai Ollama `/v1/embeddings` endpoint (nomic-embed-text). If vast.ai is down, the daily indexing inserts log nodes without embeddings and flags them for later embedding when vast.ai comes back.

**Performance**: ~500 log entries/minute, entire daily batch finishes in <10 min

#### Weekly Review (Automated, Sunday 2 AM via tokio scheduler)

**Purpose**: High-quality analysis of trends, anomaly detection, schema evolution

**Pipeline**:
```rust
pipeline::new()
    .chain(ExportWeeklyStatsOp)          // Service uptime, error rates, resource trends
    .chain(OpusAnalysisOp)               // Call Anthropic API with full context
    .chain(GenerateReportOp)             // Markdown report
    .chain(SendEmailOp)                  // Via Mailu
    .chain(UpdateKGSchemaOp)             // If Opus suggests new entity types
```

**Opus Prompt**:
```
You are a Site Reliability Engineer reviewing last week's infrastructure metrics.

Data:
- 5 VMs, 44 services, 127 container restarts, 3 alerts triggered
- Most restarted: oci-analytics/matomo (23 times, disk space issues)
- No incidents on gcp-proxy, oci-mail (stable)

Tasks:
1. Identify trends (are restarts increasing?)
2. Suggest preventive actions (e.g., increase swap on oci-analytics?)
3. Propose new KG relationships (e.g., "restart_frequency" edge weight?)

Output: JSON report with findings and actionable items.
```

**Cost**: ~$0.10/week (single Opus API call with aggregated data)

---

### Workflow 5: Agentic Framework (API Gateway)

**Purpose**: Expose Rig's intelligence to external agents (Claude Code via MCP, CLI tools, webhooks)

**HTTP API** (axum server on :8090):

```
POST   /rig/heal/trigger              # Manually trigger self-healing check
GET    /rig/heal/status               # Current health state
POST   /rig/kg/query                  # Hybrid GraphRAG query
  Body: {"query": "What depends on Authelia?", "mode": "hybrid"}
GET    /rig/kg/blast_radius/:entity   # Show impact of restarting entity
POST   /rig/agent/execute             # Multi-step agent execution
  Body: {"goal": "Optimize oci-apps disk usage", "max_steps": 5}
GET    /rig/workflows                 # List active workflows
POST   /rig/workflows/:id/pause       # Pause workflow (e.g., stop daily indexing)
```

**Multi-Agent Orchestration**:

```rust
// NOTE: Conceptual pseudocode. Actual Rig Op trait to be validated in Phase 2 spike.
struct AgentGoal {
    objective: String,           // "Free up 5GB disk space on oci-analytics"
    constraints: Vec<String>,    // ["no_data_loss", "minimize_downtime"]
    max_steps: u8,
    approval_required: bool,
}

impl AgenticFrameworkOp {
    async fn execute_goal(&self, goal: AgentGoal) -> Result<ExecutionLog> {
        let mut steps = vec![];
        let mut current_state = self.kg.get_system_state().await?;

        for step_num in 1..=goal.max_steps {
            // Ask Ollama: "Given current state, what's the next action?"
            let next_action = self.ollama.prompt(&format!(
                "Objective: {}\nCurrent: {:?}\nConstraints: {:?}\nSuggest next shell command.",
                goal.objective, current_state, goal.constraints
            )).await?;

            // Query KG for blast radius
            let blast_radius = self.kg.blast_radius(&next_action.affected_entities).await?;

            // Human approval if high risk
            if blast_radius.risk > RiskLevel::Medium && goal.approval_required {
                self.wait_for_approval(next_action, blast_radius).await?;
            }

            // Execute with guardrails
            let result = self.tool_executor.run_sandboxed(next_action.command).await?;
            steps.push(result);

            // Update KG with new state
            current_state = self.kg.get_system_state().await?;

            // Check if goal achieved
            if self.is_goal_satisfied(&goal, &current_state) {
                break;
            }
        }

        Ok(ExecutionLog { goal, steps, final_state: current_state })
    }
}
```

**Example agent execution**:
```bash
curl -X POST http://10.0.0.6:8090/rig/agent/execute \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "objective": "Investigate why PhotoPrism is slow",
    "constraints": ["read_only", "no_container_restart"],
    "max_steps": 5,
    "approval_required": false
  }'
```

Agent steps:
1. Query KG: "PhotoPrism dependencies" -> finds it's on oci-apps-1
2. SSH exec: `docker stats photoprism --no-stream` -> sees high CPU
3. SSH exec: `docker logs photoprism --tail 100` -> sees "indexing 10,000 photos"
4. Query KG: "PhotoPrism indexing history" -> finds it runs daily at 3 AM
5. Report: "PhotoPrism slowness is expected during daily indexing (3-4 AM). Current progress: 60%. ETA: 15 min."

---

## Implementation Phases

### Phase 0: Foundation — SurrealDB + Rig Skeleton (DONE)

**Goal**: Deploy SurrealDB KG and minimal Rig binary

**Completed**:
- [x] SurrealDB deployed on oci-apps :8001 with schema (13 tables, 93 edges)
- [x] `scripts/seed_from_config.sh` seeds 6 VMs, 51 services, 93 edges from config.json
- [x] Rig Rust binary with Axum HTTP server on :8090
- [x] Basic self-healing: local container check + auto-restart
- [x] KG sync: container status written to SurrealDB
- [x] Audit logging to KG
- [x] GHA pipelines for both kg-graph and rig
- [x] sops-encrypted secrets via standard build.sh pipeline
- [x] docker-service.nix module for nix-managed dockerd systemd service

---

### Phase 1: Self-Backups (NEXT — First Deploy)

**Goal**: Automated backup lifecycle for all services across all VMs. Deployed first because it's **read-only** (no mutations to running services), provides immediate safety net, and is a prerequisite for all destructive self-healing actions.

**Tasks**:
- [ ] Add `backup_record` table to SurrealDB schema
- [ ] Implement `VolumeSnapshotOp` — `docker run --rm -v <vol>:/data alpine tar czf` for each service
- [ ] Implement `DatabaseDumpOp` — SurrealDB `surreal export`, PostgreSQL `pg_dump`, MariaDB `mysqldump`
- [ ] Implement `RotationOp` — keep 7 daily, 4 weekly, 3 monthly; prune old
- [ ] Implement `RemoteSyncOp` — `rsync --delete` to `oci-apps-1:/opt/data/backups-remote/`
- [ ] Implement `VerifyBackupOp` — weekly: restore random backup to temp container, validate
- [ ] Implement `WebhookOp` — ntfy summary after each backup run
- [ ] Record all backup metadata in KG (`backup_record` table)
- [ ] Wire up tokio scheduler: daily at 2 AM
- [ ] Add `/api/backups/status` endpoint
- [ ] Add `/api/backups/trigger` endpoint (manual run)
- [ ] Deploy via GHA: `build.sh ship`

**Backup Targets**:

| VM | Target | Method | Schedule |
|---|---|---|---|
| oci-apps | SurrealDB data | `surreal export` | Daily |
| oci-apps | Docker volumes (crawlee, rig) | Volume tar | Daily |
| oci-apps-1 | PostgreSQL (NocoDB) | `pg_dump` via docker exec | Daily |
| oci-apps-1 | PhotoPrism originals index | Volume tar | Weekly |
| oci-mail | Mailu data (mail, certs) | Volume tar | Daily |
| oci-mail | Radicale calendars | Volume tar | Daily |
| oci-analytics | Matomo database (MariaDB) | `mysqldump` via docker exec | Daily |
| gcp-proxy | Authelia config + db | Volume tar | Daily |
| gcp-proxy | Vaultwarden data | Volume tar | Daily |

**Rotation Policy**:
```
/opt/data/backups/
├── daily/          # Last 7 days
├── weekly/         # Last 4 Sundays
└── monthly/        # Last 3 first-of-month
```

**Remote Redundancy**: rsync daily/ and weekly/ to `oci-apps-1:/opt/data/backups-remote/` (193GB disk, 34GB used).

**Success Criteria**:
- Backup runs at 2 AM, covers all targets, completes in <15 min
- `curl http://localhost:8090/api/backups/status` shows last backup time, size, status for each target
- After 7 days: 7 dailies exist, oldest auto-pruned on day 8
- Weekly verify passes: random backup restored to temp container, health check OK
- KG has `backup_record` entries for every run

---

### Phase 2: Hardened Self-Healing

**Goal**: Expand self-healing beyond local container restart to cross-VM health, dependency-aware restart, and ntfy escalation.

**Prerequisite**: Phase 1 (backups in place before any destructive actions)

**Tasks**:
- [ ] Cross-VM health probes (SSH + HTTP to all 6 VMs)
- [ ] Service-level health checks (hit actual health endpoints, not just Docker state)
- [ ] Dependency-aware restart ordering from KG `depends_on` edges
- [ ] Escalation: ntfy push alerts on repeated failures (3x restart fail → critical alert)
- [ ] Structured health history in KG (time series, not just current status)
- [ ] `/api/health/dashboard` endpoint — full infrastructure overview
- [ ] Implement dual-write audit log: SurrealDB + local append-only file (`/opt/data/rig/audit.jsonl`)
- [ ] Update Caddy config on gcp-proxy: add `handle /rig/*` block routing to `10.0.0.6:8090` over WireGuard

**Deliverables**:
- Health checks covering all VMs and services, not just local Docker
- Dependency-aware restart (restart db before app)
- ntfy alerts on failures

**Success Criteria**:
- Stop Authelia → Rig detects within 5 min → restarts Authelia → verifies dependent services recover → ntfy report
- `curl https://api.diegonmarcos.com/rig/health/dashboard` returns full infra status

---

### Phase 3: Self-Protection

**Goal**: Monitor and defend against threats. Observational by default, auto-remediation only for well-defined low-risk patterns.

**Tasks**:
- [ ] Implement `AuthLogMonitorOp` — parse `/var/log/auth.log`, auto-ban IPs after 5 failed SSH in 10 min
- [ ] Implement `DockerAuditOp` — detect unknown containers/images, alert via ntfy
- [ ] Implement `CertExpiryOp` — check TLS cert expiry for all domains (30d info, 14d warning, 7d critical)
- [ ] Implement `DriftDetectionOp` — compare running container state vs KG declared (image tag, ports, env)
- [ ] Implement `PortScanDetectionOp` — monitor unexpected inbound via `ss`/`conntrack`
- [ ] OCI Security List audit (weekly) — compare live firewall rules vs expected
- [ ] Add `security_event` and `drift_event` tables to KG schema
- [ ] Add `/api/security/report` endpoint
- [ ] Wire up tokio scheduler: every 10 minutes

**Deliverables**:
- SSH brute force auto-ban with KG logging
- Unknown container alerts
- TLS cert expiry monitoring
- Drift detection between declared and running state

**Success Criteria**:
- 5 failed SSH from same IP → auto-banned → ntfy alert → logged in KG
- Deploy a rogue `docker run alpine sleep 9999` → detected within 10 min → ntfy HIGH alert
- Cert with 7 days left → ntfy critical alert
- Change container env var manually → drift detected → ntfy alert

---

### Phase 4: vast.ai Automation + Ollama Connectivity

**Goal**: Reliable, automated connection to ephemeral vast.ai instances for AI-powered features

**Tasks**:
- [ ] Implement `VastAiProviderOp` in `bc-obs_rig/src/ops/vast_ai_provider.rs`
- [ ] Query vast.ai REST API for running instances (instance list, status, IP/port)
- [ ] Auto-establish SSH tunnel from oci-apps to vast.ai Ollama endpoint
- [ ] Handle IP/port changes on every rental (dynamic config update)
- [ ] Implement graceful degradation: if no instance running, mark AI features as unavailable
- [ ] Send ntfy alert on vast.ai online/offline transitions
- [ ] Test: manually start/stop vast.ai instance, verify Rig detects transitions

**Deliverables**:
- `VastAiProviderOp` that polls vast.ai API and manages SSH tunnel lifecycle
- Dynamic Ollama endpoint config

**Success Criteria**:
- Start vast.ai instance → Rig detects within 60s, tunnel established, Ollama available
- Stop instance → Rig detects, marks unavailable, sends ntfy alert

---

### Phase 5: KG Client + Embeddings + Smart Healing (AI-powered)

**Goal**: Connect Rig to KG for intelligent diagnosis, add embedding generation via vast.ai

**Tasks**:
- [ ] Implement `kg/embeddings.rs` (HTTP client to vast.ai Ollama `/v1/embeddings`)
- [ ] Update SurrealDB schema with `embedding` fields + MTREE index
- [ ] Batch embed existing docs (READMEs, service specs)
- [ ] Implement `SmartMaintenanceOp` (KG query + Ollama diagnosis)
- [ ] Implement guardrailed `SelfHealingOp` (command whitelist, dry-run, blast radius check)
- [ ] Wire up `VastAiProviderOp` status check before any AI call
- [ ] Graceful degradation: if vast.ai down, skip AI, send raw metrics via ntfy

**IMPORTANT -- SurrealDB vector::embed() does not exist**: All embeddings must be generated externally (via Ollama) and passed as parameters:
```surql
LET $vec = $externally_generated_embedding;
SELECT *, vector::similarity::cosine(embedding, $vec) AS score
FROM service WHERE embedding IS NOT NONE
ORDER BY score DESC LIMIT 10;
```

**Success Criteria**:
- Fill disk to 95% → Rig detects → KG query for similar past issues → Ollama diagnosis → ntfy approval → fix → verify
- Same with vast.ai offline → raw metrics via ntfy → human intervenes

---

### Phase 6: KG Maintenance Workflows

**Goal**: Automate daily KG freshness and weekly deep review

**Tasks**:
- [ ] Implement `DailyIndexOp` (fetch logs, embed via vast.ai Ollama, insert to KG)
- [ ] Handle missing embeddings: if vast.ai was down, re-embed on next run
- [ ] Implement `WeeklyReviewOp` (aggregate stats, call Opus 4.6 API, generate report)
- [ ] Set up tokio scheduler: daily at 3 AM, weekly Sunday 2 AM
- [ ] Implement `GraphPruneOp` (remove logs > 30 days, stale nodes)

**Deliverables**:
- KG updated daily with fresh logs and embeddings
- Weekly Opus-generated infrastructure report via email (Mailu)

**Success Criteria**:
- After 7 days, KG contains 7 days of logs with embeddings
- Weekly report received with actionable insights

---

### Phase 7: API + MCP Integration + Agentic Framework

**Goal**: Expose Rig to external agents, integrate with Claude Code MCP, enable goal-driven agent execution

**Tasks**:
- [ ] Implement full HTTP API (all endpoints from Workflow 5)
- [ ] Add `/rig/kg/query`, `/rig/agent/execute` endpoints
- [ ] Update `bb-sec_mcp-server-skills` with `kg_*` tools
- [ ] Implement Docker event listener (bollard crate) for real-time KG updates
- [ ] Implement multi-step agent execution (goal + constraints + max_steps)
- [ ] Add human-in-the-loop approval via ntfy for destructive actions
- [ ] Agent conversation memory persisted in KG

**Deliverables**:
- Rig REST API at `https://api.diegonmarcos.com/rig/`
- MCP tools in Claude Code sessions
- Goal-driven agent execution with guardrails

**Success Criteria**:
```bash
# From Claude Code MCP
kg_hybrid_search("authentication errors last week")
# Returns similar log entries + affected services + dependency chain
```
- `POST /rig/agent/execute {"goal": "Investigate PhotoPrism slowness"}` → 5-step investigation → report

---

## Security & Guardrails

### Command Execution Safety

**Whitelist regex** (allowed commands):
```rust
static ALLOWED_COMMANDS: &[&str] = &[
    r"^docker (restart|stop|start|system prune) [a-z0-9_-]+$",
    r"^systemctl (restart|reload) [a-z0-9_-]+\.service$",
    r"^rm -rf /tmp/[a-z0-9_/-]+$",
    r"^journalctl --vacuum-size=[0-9]+M$",
    r"^nix-collect-garbage -d$",
];
```

**Blacklist paths** (forbidden):
```rust
static FORBIDDEN_PATHS: &[&str] = &[
    "/nix/store",
    "/home",
    "/etc/nixos",
    "/etc/wireguard",
    "/opt/data/surrealdb",  // Don't let AI delete the KG!
];
```

**Dry-run first**:
```rust
impl SelfHealingOp {
    async fn execute_with_guardrails(&self, cmd: String) -> Result<Output> {
        // 1. Validate against whitelist
        if !self.is_allowed(&cmd) {
            return Err("Command not in whitelist");
        }

        // 2. Check for forbidden paths
        if self.touches_forbidden_path(&cmd) {
            return Err("Command touches forbidden path");
        }

        // 3. Dry run (if command supports it)
        if let Some(dry_cmd) = self.to_dry_run(&cmd) {
            let dry_result = self.ssh_exec(&dry_cmd).await?;
            self.log_dry_run(dry_result);
        }

        // 4. Risk assessment via KG
        let blast_radius = self.kg.blast_radius(&cmd).await?;
        if blast_radius.risk > RiskLevel::Medium {
            self.request_human_approval(&cmd, blast_radius).await?;
        }

        // 5. Execute with timeout
        let result = tokio::time::timeout(
            Duration::from_secs(60),
            self.ssh_exec(&cmd)
        ).await??;

        // 6. Audit log (dual-write: SurrealDB + local file)
        self.audit.log(&cmd, &result).await;

        // 7. Verify system still healthy
        let post_health = HealthCheckOp.call(()).await?;
        if !post_health.is_healthy() {
            self.alert_failed_healing(&cmd, post_health).await?;
        }

        Ok(result)
    }
}
```

### Access Control

**API Authentication**:
- All `/rig/` endpoints require Authelia bearer token (same as other services)
- Human approval requests via ntfy include one-time approval token

**SSH Key Management**:
- Rig uses dedicated SSH key: `~/git/vault/A0_keys/ssh/rig_id_ed25519`
- Only has access to specific commands via `authorized_keys` restrictions:
  ```
  command="/opt/bin/rig-executor.sh",no-pty,no-port-forwarding ssh-ed25519 AAAA...
  ```

**Audit Log** (dual-write for resilience):
- Primary: SurrealDB `audit_log` table
- Fallback: Local append-only file at `/opt/data/rig/audit.jsonl`
- If SurrealDB is down, the local file ensures audit trail survives

```surql
CREATE audit_log CONTENT {
    timestamp: time::now(),
    workflow: "self_healing",
    command: "docker system prune -af",
    risk_level: "medium",
    human_approved: true,
    result: "success",
    freed_space_mb: 3500
};
```

```json
// /opt/data/rig/audit.jsonl (one JSON object per line, append-only)
{"timestamp":"2026-02-16T14:30:00Z","workflow":"self_healing","command":"docker system prune -af","risk_level":"medium","human_approved":true,"result":"success","freed_space_mb":3500}
```

---

## Resource Budget

### oci-apps (16GB RAM, 3 vCPU, aarch64)

After stopping quant-lab-full (set to manual-only restart, freeing ~3GB RAM and CPU):

| Component | RAM | CPU | Disk | Port |
|-----------|-----|-----|------|------|
| **quant-light** (3 containers) | ~800MB | 0.3 | 2GB | various |
| **crawlee** (7 containers) | ~1.5GB | 0.5 | 3GB | 3000/3001 |
| **OS + Docker overhead** | ~1.5GB | 0.3 | 2GB | - |
| **SurrealDB** | ~150MB | 0.1 | 500MB | 8001 |
| **Rig Orchestrator** | ~30MB | 0.2 | 20MB | 8090 |
| **TOTAL USED** | **~4.0GB** | **1.4** | **7.5GB** | - |
| **AVAILABLE** | **~12GB** | **1.6** | **~18GB free** | - |

**Key notes**:
- No local Ollama. All AI inference via vast.ai only.
- 12GB free RAM is more than sufficient for SurrealDB + Rig binary.
- Disk: 18GB free currently (45GB total, 27GB used). Can resize from oci-apps-1 if needed (oci-apps-1 has 193GB total, only 34GB used). OCI free tier allows redistribution.

### vast.ai (RTX A4000, 16GB VRAM)

| Component | VRAM | Cost/hr |
|-----------|------|---------|
| **Ollama 14B (Q4)** | 8.5GB | $0.08-0.25 |
| **nomic-embed-text** | 500MB | (same instance) |
| **FREE** | 7GB | - |

**Usage pattern**:
- Only spun up when Rig needs reasoning (anomaly detected) or batch embeddings (daily indexing)
- Instances are ephemeral: IP/port change on every rental
- `VastAiProviderOp` manages discovery and SSH tunnel lifecycle
- Average: ~2 hrs/week = $0.50-1.00/week = **$2-4/month**

---

## Testing Strategy

### Unit Tests (Rust)

```rust
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn test_health_check_op() {
        let op = HealthCheckOp::new();
        let result = op.call(()).await.unwrap();
        assert!(result.disk_usage_percent < 100);
    }

    #[tokio::test]
    async fn test_command_whitelist() {
        let op = SelfHealingOp::new();
        assert!(op.is_allowed("docker restart authelia"));
        assert!(!op.is_allowed("rm -rf /"));
    }

    #[tokio::test]
    async fn test_kg_hybrid_search() {
        let kg = GraphRAGQuery::new_mock();
        let results = kg.hybrid_search("disk full error").await.unwrap();
        assert!(!results.is_empty());
    }

    #[tokio::test]
    async fn test_audit_dual_write() {
        // Verify audit writes to both SurrealDB and local file
        let audit = AuditLog::new_test();
        audit.log("docker restart foo", &Ok("success")).await;
        assert!(audit.surreal_has_entry("docker restart foo").await);
        assert!(audit.local_file_has_entry("docker restart foo"));
    }

    #[tokio::test]
    async fn test_vast_ai_degradation() {
        // Verify AI ops skip gracefully when vast.ai is offline
        let provider = VastAiProviderOp::new_mock(/* online = */ false);
        let op = SmartMaintenanceOp::new(provider);
        let result = op.call(unhealthy_status()).await.unwrap();
        assert!(result.skipped_ai);
        assert!(result.ntfy_alert_sent);
    }
}
```

### Integration Tests (Bash)

```bash
#!/bin/bash
# test/integration/self_healing_test.sh

# 1. Fill disk to 95%
ssh oci-apps "dd if=/dev/zero of=/tmp/fill bs=1G count=10"

# 2. Trigger Rig health check
curl -X POST http://10.0.0.6:8090/rig/heal/trigger

# 3. Wait for self-healing to complete (timeout 5 min)
for i in $(seq 1 60); do
  STATUS=$(curl -s http://10.0.0.6:8090/rig/heal/status | jq -r .status)
  if [ "$STATUS" = "healthy" ]; then
    echo "PASS: Self-healing successful"
    exit 0
  fi
  sleep 5
done

echo "FAIL: Self-healing timed out"
exit 1
```

### End-to-End Test (Synthetic Incident)

1. Deploy all components to oci-apps
2. Inject synthetic error: Stop Authelia container
3. Observe:
   - Rig detects unhealthy state within 5 min
   - KG query finds Authelia dependencies (Vaultwarden, PhotoPrism, etc.)
   - Ollama diagnoses: "Authelia down, all protected services unreachable"
   - SelfHealingOp executes: `docker start authelia`
   - Verify all dependent services become reachable
   - Webhook sent to ntfy with incident report
4. Check KG now contains new `log` node with "authelia_restart_incident" linked to affected services
5. Check `/opt/data/rig/audit.jsonl` contains the incident entry

---

## Deployment Checklist

### Pre-Deployment

- [ ] Rust 1.75+ installed on oci-apps (via home-manager)
- [ ] SurrealDB 2.0+ container image pulled (aarch64)
- [ ] vast.ai account configured with API key for `VastAiProviderOp`
- [ ] SSH keys generated for Rig (`~/git/vault/A0_keys/ssh/rig_id_ed25519`)
- [ ] ntfy topic created: `https://rss.diegonmarcos.com/rig-alerts`
- [ ] Authelia bearer token for Rig API generated
- [ ] Caddy config on gcp-proxy updated: `handle /rig/*` -> `10.0.0.6:8090`
- [ ] SurrealDB backup configured (borg/bup to oci-apps-1)

### Deployment Steps

```bash
# 1. Deploy SurrealDB
cd ~/git/cloud/a_solutions/container-nix/ca-dat_kg-graph
./build.sh ship

# 2. Seed initial graph (auto-infers dependencies from configs)
ssh oci-apps
cd /opt/containers/ca-dat_kg-graph
./scripts/seed_from_config.sh

# 3. Build and deploy Rig
cd ~/git/cloud/a_solutions/container-nix/bc-obs_rig
cargo test --release  # Run tests first
./build.sh ship       # Build on oci-apps (aarch64)

# 4. Enable systemd service
ssh oci-apps "sudo systemctl enable --now rig-orchestrator.service"

# 5. Verify health
curl https://api.diegonmarcos.com/rig/heal/status \
  -H "Authorization: Bearer $TOKEN"
# Expected: {"status": "healthy", "workflows": ["self_healing", "kg_maintenance"]}

# 6. Test self-healing manually
ssh oci-apps "dd if=/dev/zero of=/tmp/fill bs=1G count=5"  # Simulate disk fill
curl -X POST https://api.diegonmarcos.com/rig/heal/trigger \
  -H "Authorization: Bearer $TOKEN"
# Wait for ntfy notification
```

Note: No cron setup needed. All scheduling is handled internally by `tokio::time::interval`.

### Post-Deployment

- [ ] Monitor Rig logs: `ssh oci-apps "journalctl -u rig-orchestrator -f"`
- [ ] Verify audit dual-write: check both SurrealDB entries and `/opt/data/rig/audit.jsonl`
- [ ] Verify KG daily updates: Check SurrealDB for new log entries each day
- [ ] First weekly review: Wait for Sunday 2 AM, check email for Opus report
- [ ] Update MCP server: `cd ~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills && ./build.sh deploy`
- [ ] Test MCP tools in Claude Code: Try `kg_hybrid_search("authentication")`

---

## Documentation

### Required Documentation Files

1. **bc-obs_rig/docs/API.md** - REST API reference
2. **bc-obs_rig/docs/WORKFLOWS.md** - Detailed workflow logic diagrams
3. **bc-obs_rig/README.md** - Quick start, architecture overview
4. **ca-dat_kg-graph/README.md** - Schema documentation, query examples

### User-Facing Documentation

**To be added to `~/git/cloud/README.md`**:

```markdown
## Rig Intelligence Framework

**Status**: Active (oci-apps)
**Purpose**: Autonomous cloud maintenance + GraphRAG

### Quick Start

**Trigger manual health check**:
```bash
curl -X POST https://api.diegonmarcos.com/rig/heal/trigger \
  -H "Authorization: Bearer $TOKEN"
```

**Query the Knowledge Graph**:
```bash
curl -X POST https://api.diegonmarcos.com/rig/kg/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "What services depend on Authelia?", "mode": "hybrid"}'
```

**Use via MCP (in Claude Code)**:
```
kg_hybrid_search("disk space errors last week")
kg_blast_radius("service", "matomo")
```

For full API docs: See `~/git/cloud/a_solutions/container-nix/bc-obs_rig/docs/API.md`
```

---

## Success Metrics

### Key Performance Indicators

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Self-Healing Success Rate** | >90% | Incidents resolved without human intervention |
| **Mean Time to Detection (MTTD)** | <5 min | Time from issue occurrence to Rig detection |
| **Mean Time to Repair (MTTR)** | <10 min | Time from detection to resolution |
| **False Positive Rate** | <5% | Unnecessary alerts/fixes |
| **KG Query Latency** | <500ms | Hybrid search response time |
| **AI Inference Cost** | <$5/month | vast.ai + Opus API combined |
| **Zero Unplanned Downtime** | 100% | No service outages due to unhandled issues |

### Long-Term Goals (6 months)

- [ ] **Predictive Maintenance**: Rig predicts disk full 48 hours in advance, pre-heals
- [ ] **Multi-Cloud Awareness**: Extend KG to include GCP/OCI API state (not just Docker)
- [ ] **Agent Collaboration**: Multiple Rig instances coordinate (e.g., gcp-proxy Rig + oci-apps Rig)
- [ ] **Self-Improvement**: Opus weekly reviews suggest new Rig Ops, auto-generate code PRs

---

## Future Enhancements

### Phase 7+: Advanced Features

1. **Federated KG**: Each VM runs local Rig + mini-KG, syncs to central oci-apps KG
2. **Time-Travel Queries**: "What did the infrastructure look like 3 days ago before the incident?"
3. **Chaos Engineering Integration**: Rig deliberately injects failures, observes self-healing
4. **Natural Language Ops**: "Rig, why is PhotoPrism slow?" -> Automatic investigation + report
5. **Cost Optimization Agent**: Analyze resource usage, suggest VM downgrades, container consolidation

---

## Support & Maintenance

### Who Owns What

| Component | Primary Maintainer | Repo | Contact |
|-----------|-------------------|------|---------|
| **Rig Orchestrator** | Diego | `~/git/cloud/a_solutions/container-nix/bc-obs_rig/` | GitHub Issues |
| **SurrealDB KG** | Diego | `~/git/cloud/a_solutions/container-nix/ca-dat_kg-graph/` | GitHub Issues |
| **MCP Integration** | Diego | `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/` | GitHub Issues |
| **vast.ai Ollama** | Diego | `~/git/cloud/b_infra/vm_vast-RTX-p_0/` | vast.ai support |

### Runbook: Common Issues

**Issue**: Rig not responding
**Diagnosis**: `ssh oci-apps "systemctl status rig-orchestrator"`
**Fix**: `ssh oci-apps "systemctl restart rig-orchestrator"`

**Issue**: KG queries timing out
**Diagnosis**: `ssh oci-apps "docker logs surrealdb"`
**Fix**: Check SurrealDB disk space, restart container if needed

**Issue**: Ollama 14B unreachable (vast.ai)
**Diagnosis**: Check if vast.ai instance is running (`VastAiProviderOp` status via `/rig/heal/status`)
**Fix**: No local fallback. AI-dependent features degrade gracefully. Start a new vast.ai instance manually if needed, Rig will auto-detect it.

**Issue**: Self-healing stuck in loop
**Diagnosis**: Check `max_retries` in audit log (both SurrealDB and `/opt/data/rig/audit.jsonl`)
**Fix**: Manually resolve issue, reset workflow state via API

**Issue**: Audit log divergence (SurrealDB vs local file)
**Diagnosis**: Compare entry counts between SurrealDB `audit_log` table and `/opt/data/rig/audit.jsonl`
**Fix**: The local file is the source of truth. Replay missing entries to SurrealDB.

---

## Appendix

### A. SurrealDB Schema (Full)

See `ca-dat_kg-graph/src/schema.surql` (generated in Phase 1)

### B. Rig Configuration

```toml
# bc-obs_rig/config.toml
[kg]
url = "http://localhost:8001"
namespace = "infra"
database = "production"

[vast_ai]
api_key_path = "/opt/keys/vast_ai_api_key"  # vast.ai REST API key
poll_interval_sec = 60                        # Check for running instances
ssh_key_path = "/opt/keys/rig_id_ed25519"    # For SSH tunnel to vast.ai

[ollama]
# Dynamic - set by VastAiProviderOp when instance is discovered
# url = "http://<dynamic-ip>:<dynamic-port>/v1"
model = "qwen2.5:14b-instruct-q4_K_M"
embed_model = "nomic-embed-text"

[self_healing]
check_interval_sec = 300  # 5 minutes (tokio::time::interval)
max_retries = 3
human_approval_threshold = "medium"  # low, medium, high

[notifications]
ntfy_url = "https://rss.diegonmarcos.com/rig-alerts"
email_to = "me@diegonmarcos.com"
email_from = "rig@diegonmarcos.com"

[ssh]
key_path = "/opt/keys/rig_id_ed25519"
known_hosts = "/opt/keys/known_hosts"

[audit]
log_all_commands = true
retention_days = 90
local_file = "/opt/data/rig/audit.jsonl"  # Append-only fallback
```

### C. Glossary

- **GraphRAG**: Graph-enhanced Retrieval Augmented Generation (vector search + graph traversal)
- **Rig**: Rust framework for building LLM-powered pipelines with typed Ops
- **Op**: Operation - a unit of work in a Rig pipeline (e.g., HealthCheckOp). Note: trait signatures in this document are conceptual pseudocode.
- **Blast Radius**: The set of entities affected by an action (e.g., restarting a VM affects all services on it)
- **Hybrid KG**: Knowledge Graph with both graph relationships and vector embeddings
- **SurrealDB**: Multi-model database (graph + document + vector) written in Rust
- **LightRAG**: Lightweight framework for incremental Knowledge Graph updates
- **VastAiProviderOp**: Rig Op that manages ephemeral vast.ai instance discovery and SSH tunnel lifecycle

---

## Sign-Off

**Plan Author**: Claude Sonnet 4.5 + Claude Opus 4.6 (Review)
**Reviewed By**: Diego Nepomuceno Marcos (Human)
**Status**: Revised after Opus review
**Start Date**: 2026-02-16
**Target Completion**: 2026-03-30 (7 weeks)

**Approval**: _______________ (Diego's signature once plan is accepted)

---

**END OF MASTER PLAN**
