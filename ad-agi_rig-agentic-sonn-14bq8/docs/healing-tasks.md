# Healing Tasks — Deployment & Test Checklist

> Living document. Updated as each phase is deployed and verified.
> Plan reference: [healing-plan.md](./healing-plan.md)

---

## Phase 0: Foundation (SurrealDB + Rig Skeleton)

### Deployment
- [x] SurrealDB container deployed on oci-apps :8001
- [x] Schema loaded: 13 tables (vm, service, container, log, documentation, audit_log + edges)
- [x] Seed script: 6 VMs, 51 services, 93 edges from config.json
- [x] Rig Rust binary deployed on oci-apps :8090
- [x] GHA workflow: `ship-kg-graph.yml` (with wipe_data option)
- [x] GHA workflow: `ship-rig.yml` (aarch64 on-VM build)
- [x] sops-encrypted `src/secrets.yaml` for both services
- [x] docker-service.nix module for nix-managed dockerd
- [x] ssh-keyscan `|| true` fix in all GHA workflows

### Tests Passed
- [x] SurrealDB health: `curl -sf http://localhost:8001/health` returns OK
- [x] Rig health: `curl -sf http://localhost:8090/health` returns OK
- [x] Rig /api/status: returns VM count (6), service count (51), audit entries
- [x] Self-healing cycle: detects unhealthy containers, auto-restarts (skips itself)
- [x] Container status synced to KG after each cycle
- [x] Audit log entries written to KG on restart actions
- [x] GHA ship-kg-graph: full pipeline passes (build + secrets + deploy + compose)
- [x] GHA ship-rig: full pipeline passes (build + secrets + deploy + docker build on-VM)
- [x] GHA ship-kg-graph with wipe_data=true: wipe + re-seed passes

### Known Issues
- Self-healing only checks local oci-apps containers (no cross-VM)
- No ntfy alerts yet
- No dual-write audit (SurrealDB only, no local file fallback)
- Crawlee scheduler container keeps restarting (pre-existing, not caused by rig)

---

## Phase 1: Self-Backups

### Deployment
- [ ] `backup_record` table added to SurrealDB schema
- [ ] `VolumeSnapshotOp` implemented and tested
- [ ] `DatabaseDumpOp` implemented (SurrealDB, PostgreSQL, MariaDB)
- [ ] `RotationOp` implemented (7d/4w/3m)
- [ ] `RemoteSyncOp` implemented (rsync to oci-apps-1)
- [ ] `VerifyBackupOp` implemented (weekly restore to temp container)
- [ ] `WebhookOp` wired for backup ntfy summary
- [ ] Tokio scheduler: daily at 2 AM
- [ ] `/api/backups/status` endpoint live
- [ ] `/api/backups/trigger` endpoint live
- [ ] GHA deploy passes

### Tests Passed
- [ ] Manual trigger: `curl POST /api/backups/trigger` completes all targets
- [ ] SurrealDB export: file created, non-zero size
- [ ] Volume tar: each target produces valid .tar.gz
- [ ] PostgreSQL pg_dump (NocoDB on oci-apps-1): dump file valid
- [ ] MariaDB mysqldump (Matomo on oci-analytics): dump file valid
- [ ] Rotation: after 8 days, only 7 dailies exist
- [ ] Remote sync: backups visible on oci-apps-1
- [ ] Verify: random backup restored to temp container, health check passes
- [ ] KG: `backup_record` entries created for each run
- [ ] ntfy: summary notification received after backup run
- [ ] Scheduler: runs automatically at 2 AM (verify next morning)

### Known Issues
- (none yet)

---

## Phase 2: Hardened Self-Healing

### Deployment
- [ ] Cross-VM health probes (SSH + HTTP to all 6 VMs)
- [ ] Service-level health checks (actual health endpoints)
- [ ] Dependency-aware restart ordering from KG edges
- [ ] ntfy escalation (3x fail → critical)
- [ ] Health history in KG (time series)
- [ ] `/api/health/dashboard` endpoint live
- [ ] Dual-write audit log (SurrealDB + local `/opt/data/rig/audit.jsonl`)
- [ ] Caddy route: `handle /rig/*` on gcp-proxy

### Tests Passed
- [ ] Probe all 6 VMs via SSH — all reachable
- [ ] Probe all services via health endpoints — all respond
- [ ] Stop Authelia → detected within 5 min → restarted → dependents recover
- [ ] Dependency ordering: db restarted before app
- [ ] 3x restart failure → ntfy critical alert received
- [ ] `/api/health/dashboard` returns all VMs and services status
- [ ] Dual-write: entry in both SurrealDB and audit.jsonl
- [ ] External access: `curl https://api.diegonmarcos.com/rig/health/dashboard` works

### Known Issues
- (none yet)

---

## Phase 3: Self-Protection

### Deployment
- [ ] `AuthLogMonitorOp` — SSH fail2ban
- [ ] `DockerAuditOp` — unknown container detection
- [ ] `CertExpiryOp` — TLS cert monitoring
- [ ] `DriftDetectionOp` — running vs declared state
- [ ] `PortScanDetectionOp` — unexpected inbound
- [ ] `security_event` and `drift_event` tables in KG
- [ ] `/api/security/report` endpoint live
- [ ] Scheduler: every 10 minutes

### Tests Passed
- [ ] 5 failed SSH from same IP → auto-banned → ntfy alert → KG entry
- [ ] Rogue container `docker run alpine sleep 9999` → detected → ntfy HIGH
- [ ] Cert with <7 days → ntfy critical alert
- [ ] Manual env var change on container → drift detected → ntfy alert
- [ ] OCI security list audit: matches expected rules

### Known Issues
- (none yet)

---

## Phase 4: vast.ai Automation

### Deployment
- [ ] `VastAiProviderOp` implemented
- [ ] SSH tunnel auto-management
- [ ] Graceful degradation (AI unavailable → skip)
- [ ] ntfy alerts on online/offline transitions

### Tests Passed
- [ ] Start vast.ai → detected in 60s → tunnel established
- [ ] Stop vast.ai → detected → ntfy alert
- [ ] AI-dependent op with vast.ai down → skips gracefully

### Known Issues
- (none yet)

---

## Phase 5: KG Embeddings + Smart Healing

### Deployment
- [ ] `kg/embeddings.rs` — vast.ai Ollama client
- [ ] MTREE vector index on SurrealDB
- [ ] Batch embed existing docs
- [ ] `SmartMaintenanceOp` — KG + Ollama diagnosis
- [ ] Guardrailed `SelfHealingOp` — whitelist, dry-run, blast radius

### Tests Passed
- [ ] Vector similarity search returns relevant results
- [ ] Disk 95% → KG query → Ollama diagnosis → ntfy approval → fix → verify
- [ ] Same with vast.ai offline → raw metrics via ntfy

### Known Issues
- (none yet)

---

## Phase 6: KG Maintenance

### Deployment
- [ ] `DailyIndexOp` — logs + embeddings
- [ ] `WeeklyReviewOp` — Opus 4.6 analysis
- [ ] `GraphPruneOp` — remove stale data
- [ ] Scheduler: daily 3 AM, weekly Sunday 2 AM

### Tests Passed
- [ ] After 7 days: KG has 7 days of logs with embeddings
- [ ] Weekly report received via email with actionable insights
- [ ] Stale nodes (>30 days) pruned

### Known Issues
- (none yet)

---

## Phase 7: API + MCP + Agentic Framework

### Deployment
- [ ] Full REST API live at `https://api.diegonmarcos.com/rig/`
- [ ] MCP tools (`kg_*`) in `bb-sec_mcp-server-skills`
- [ ] Docker event listener (bollard) for real-time KG updates
- [ ] Multi-step agent execution with guardrails
- [ ] Agent conversation memory in KG

### Tests Passed
- [ ] MCP: `kg_hybrid_search("authentication errors")` returns results
- [ ] Agent: `POST /rig/agent/execute` completes investigation goal
- [ ] Human-in-the-loop: destructive action → ntfy approval required
- [ ] Docker event → KG updated within 10 seconds

### Known Issues
- (none yet)
