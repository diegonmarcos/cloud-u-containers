# Dagu - Workflow Scheduler

Lightweight DAG-based workflow scheduler for infrastructure monitoring.
All workflows send alerts to [ntfy](https://rss.diegonmarcos.com) channels via HTTP POST with bearer token auth.

## Deployment

| Key | Value |
|-----|-------|
| **VM** | oci-mail (10.0.0.3) |
| **Port** | 8070 |
| **Image** | `ghcr.io/dagucloud/dagu:2.5.0` |
| **UI** | https://workflows.diegonmarcos.com |
| **DAGs dir** | `/var/lib/dagu/dags` (read-only mount from `./dags/`) |
| **CI/CD** | `ship-oci-mail.yml` on push to `a_solutions/bc-obs_dagu/src/**` |

---

## Workflow Plan

### TIER 1 — Critical (real-time)

| Workflow | Channel | Schedule | Scope | Status |
|----------|---------|----------|-------|--------|
| `mesh-health` | `infra` | `*/5 * * * *` | WireGuard peer reachability (hub, mail, analytics) | DONE |
| `service-endpoints` | `infra` | `*/5 * * * *` | HTTP 200 probe: auth, vault, mail, api, proxy, analytics | TODO |

### TIER 2 — Daily Operations (morning sweep)

| Workflow | Channel | Schedule | Scope | Status |
|----------|---------|----------|-------|--------|
| `system-resources` | `system` | `0 9 * * *` | Disk/mem/load on ALL 5 VMs via SSH | PARTIAL (local only) |
| `container-health` | `docker` | `0 10 * * *` | Unhealthy/exited/restart-loop on ALL VMs via SSH | PARTIAL (local only) |
| `backup-freshness` | `backup` | `0 11 * * *` | Borg, bup, db-agent backups across all VMs | PARTIAL (local only) |
| `security-audit` | `security` | `0 12 * * *` | SSH failures, root logins, sudo on ALL VMs via SSH | PARTIAL (local only) |
| `tls-expiry` | `security` | `0 8 * * *` | Certificate expiry check for all 15+ domains | TODO |
| `dns-resolution` | `infra` | `0 8 * * *` | Verify all domains resolve (Cloudflare + Hickory) | TODO |
| `auth-events` | `auth` | `0 9 * * *` | Aggregate SSH/PAM events from all VMs, forward to ntfy | TODO |
| `cron-status` | `cron` | `0 7 * * *` | Check cron/systemd-timer failures across all VMs | TODO |

### TIER 3 — Daily Summary (evening)

| Workflow | Channel | Schedule | Scope | Status |
|----------|---------|----------|-------|--------|
| `ops-summary` | `ops` | `0 18 * * *` | Aggregated daily report (uptime + container count) | DONE (basic) |
| `deploy-digest` | `deploy` | `0 19 * * *` | Summarize GHA deployments from last 24h via `gh` CLI | TODO |

### TIER 4 — Weekly Deep Checks

| Workflow | Channel | Schedule | Scope | Status |
|----------|---------|----------|-------|--------|
| `sauron-integrity` | `sauron` | `0 3 * * 0` | Verify all 4 sauron-lite scanners are reporting | TODO |
| `capacity-review` | `ops` | `0 9 * * 1` | Storage trends, image sizes, volume usage | TODO |

---

## ntfy Channel Map

| Channel | Source(s) | Type | Status |
|---------|-----------|------|--------|
| `infra` | `mesh-health` DAG, `service-endpoints` DAG, `dns-resolution` DAG | Scheduled | PARTIAL |
| `system` | `system-resources` DAG | Scheduled | PARTIAL |
| `docker` | `container-health` DAG | Scheduled | PARTIAL |
| `backup` | `backup-freshness` DAG | Scheduled | PARTIAL |
| `security` | `security-audit` DAG, `tls-expiry` DAG | Scheduled | PARTIAL |
| `ops` | `ops-summary` DAG, `capacity-review` DAG | Scheduled | PARTIAL |
| `github` | github-rss bridge (event-driven) | Bridge | DONE |
| `auth` | `auth-events` DAG (replaces dead syslog-bridge route) | Scheduled | TODO |
| `sauron` | syslog-bridge (FIX: topic `sauron-alerts` → `sauron`), `sauron-integrity` DAG | Bridge + Scheduled | BROKEN |
| `cron` | `cron-status` DAG (no source exists today) | Scheduled | TODO |
| `deploy` | `deploy-digest` DAG (no source exists today) | Scheduled | TODO |

---

## Fixes Required

### 1. Syslog Bridge — Wrong Topic
**File**: `bc-obs_ntfy/src/syslog-to-ntfy.py`
**Problem**: Sends to `sauron-alerts` instead of `sauron`
**Fix**: Change `NTFY_TOPIC = 'sauron-alerts'` → `NTFY_TOPIC = 'sauron'`

### 2. Existing Workflows — Single-VM Scope
**Problem**: `system-check`, `docker-check`, `backup-check`, `security-audit` only run locally on oci-mail
**Fix**: Add SSH-based steps for each VM (gcp-proxy, oci-apps, oci-apps-1, oci-analytics)

### 3. Dead Channels — No Source
**Problem**: `auth`, `cron`, `deploy` channels exist in topic-scanner config but nothing sends to them
**Fix**: Create dedicated DAG workflows that aggregate events and forward to ntfy

---

## Implementation Priority

```
Phase 1 (Critical):
  [x] mesh-health (infra)
  [ ] service-endpoints (infra) — catch outages before users do
  [ ] Fix sauron bridge topic name

Phase 2 (Multi-VM expansion):
  [ ] Expand system-resources to ALL 5 VMs
  [ ] Expand container-health to ALL VMs
  [ ] Expand security-audit to ALL VMs
  [ ] Expand backup-freshness to ALL VMs

Phase 3 (Fill dead channels):
  [ ] auth-events — aggregate SSH/PAM logs
  [ ] cron-status — check timer/cron failures
  [ ] deploy-digest — summarize GHA deploys
  [ ] tls-expiry — certificate monitoring
  [ ] dns-resolution — domain verification

Phase 4 (Weekly deep checks):
  [ ] sauron-integrity — verify scanners running
  [ ] capacity-review — storage trends
```

---

## Build & Deploy

```bash
bash build.sh ship    # Full pipeline: build → deploy → compose
bash build.sh build   # Build only (generates dist/)
```
