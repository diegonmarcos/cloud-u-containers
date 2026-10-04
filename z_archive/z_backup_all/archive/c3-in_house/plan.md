# C3 - Cloud Control Center

> **Status:** Planning
> **Owner:** Diego Nepomuceno Marcos
> **Last Updated:** 2024-12-28

---

## Table of Contents

### Part A: What We Are Building
1. [Problem Statement](#a1-problem-statement)
2. [Vision](#a2-vision)
3. [Scope](#a3-scope)
4. [Requirements](#a4-requirements)
5. [Success Metrics](#a5-success-metrics)

### Part B: What We Need to Build It
6. [Architecture Overview](#b1-architecture-overview)
7. [Knowledge Forms & Data Model](#b2-knowledge-forms--data-model)
8. [Technology Stack](#b3-technology-stack)
9. [Pillar Specifications](#b4-pillar-specifications)
   - [B4.1 Metrics](#b41-metrics)
   - [B4.2 Logs](#b42-logs)
   - [B4.3 Traces](#b43-traces)
   - [B4.4 Profiling](#b44-profiling)
   - [B4.5 APM](#b45-apm)
   - [B4.6 Uptime](#b46-uptime)
   - [B4.7 SIEM](#b47-siem)
   - [B4.8 Network](#b48-network)
   - [B4.9 Firewall](#b49-firewall)
   - [B4.10 Auth](#b410-auth)
   - [B4.11 Incidents](#b411-incidents)
   - [B4.12 Chaos](#b412-chaos)
   - [B4.13 Cost](#b413-cost)
   - [B4.14 Docs/Runbooks](#b414-docsrunbooks)
10. [Implementation Phases](#b5-implementation-phases)

---

# Part A: What We Are Building

---

## A.1 Problem Statement

### Current Pain Points

| Problem | Impact | Frequency |
|---------|--------|-----------|
| No centralized logging | SSH into each VM to debug | Daily |
| No metrics dashboard | Blind to resource usage until failure | Weekly |
| No alerting system | Discover outages from users, not monitors | Monthly |
| No security visibility | Unknown if under attack | Unknown |
| Manual incident response | No runbooks, no escalation | Per incident |

### Current State

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│oci-micro-1  │  │oci-micro-2  │  │gcp-micro-1  │  │oci-flex-1   │
│   (mail)    │  │ (analytics) │  │  (proxy)    │  │  (photos)   │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │                │
       ▼                ▼                ▼                ▼
   [logs lost]     [logs lost]     [logs lost]     [logs lost]
   [no metrics]    [no metrics]    [no metrics]    [no metrics]
   [no alerts]     [no alerts]     [no alerts]     [no alerts]
```

---

## A.2 Vision

### Target State

A unified observability platform that answers:
- **HEALTH:** Is it working? Is it fast? Where's the bug?
- **SECURITY:** Is it safe? Who accessed? Any threats?
- **OPERATIONS:** Can we manage it? What if it fails? Who fixes it?

```
┌─────────────────────────────────────────────────────────────────────┐
│                              C3                                      │
│                    Cloud Control Center                              │
├─────────────────────┬─────────────────────┬─────────────────────────┤
│   HEALTH (What)     │  SECURITY (Who)     │  OPERATIONS (How)       │
├─────────────────────┼─────────────────────┼─────────────────────────┤
│  • Metrics          │  • SIEM             │  • Incident Mgmt        │
│  • Logs             │  • Network Monitor  │  • Chaos Engineering    │
│  • Traces           │  • Firewall Logs    │  • Runbooks             │
│  • Profiling        │  • Auth Logs        │  • On-call Schedules    │
│  • APM              │  • Intrusion Detect │  • Cost Management      │
│  • Uptime           │                     │  • Capacity Planning    │
├─────────────────────┼─────────────────────┼─────────────────────────┤
│  "Is it working?"   │  "Is it safe?"      │  "Can we manage it?"    │
│  "Is it fast?"      │  "Who accessed?"    │  "What if it fails?"    │
│  "Where's the bug?" │  "Any threats?"     │  "Who fixes it?"        │
└─────────────────────┴─────────────────────┴─────────────────────────┘
```

---

## A.3 Scope

### In Scope (MVP)

| Pillar | Priority | Justification |
|--------|----------|---------------|
| Metrics | P0 | Blind without resource visibility |
| Logs | P0 | Can't debug without centralized logs |
| Uptime | P0 | Must know when services are down |
| Alerts | P0 | Must be notified of issues |
| Firewall | P1 | Basic security visibility |
| Auth | P1 | Track who accesses what |

### Out of Scope (Future)

| Pillar | Phase | Reason |
|--------|-------|--------|
| Traces | Phase 2 | Requires app instrumentation |
| Profiling | Phase 2 | Requires code changes |
| APM | Phase 2 | Depends on traces |
| SIEM | Phase 2 | Advanced security |
| Network | Phase 2 | Nice to have |
| Incidents | Phase 3 | Solo dev, low priority |
| Chaos | Phase 3 | Advanced testing |
| Cost | Phase 3 | Manual tracking sufficient |

---

## A.4 Requirements

### Functional Requirements

| ID | Requirement | Acceptance Criteria |
|----|-------------|---------------------|
| FR-01 | Collect metrics from all VMs | CPU, RAM, disk, network visible in dashboard |
| FR-02 | Centralize logs from all containers | Search logs by container, time, keyword |
| FR-03 | Monitor endpoint availability | HTTP/TCP checks every 60s |
| FR-04 | Send alerts on failures | Notification within 2 min of issue |
| FR-05 | Track authentication events | See login attempts, 2FA, failures |
| FR-06 | Log firewall blocks | See blocked IPs, ports, reasons |

### Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-01 | Resource usage | < 1GB RAM total for observability stack |
| NFR-02 | Data retention | 30 days logs, 90 days metrics |
| NFR-03 | Query latency | < 2s for dashboard load |
| NFR-04 | Availability | Observability stack must be more reliable than monitored services |
| NFR-05 | Cost | $0 additional (use existing free tier VMs) |

### Constraints

| Constraint | Description |
|------------|-------------|
| RAM | Free tier VMs have 1GB RAM each |
| Storage | 47-100GB per VM |
| Network | Cross-cloud traffic should be minimal |
| Complexity | Solo dev, must be maintainable |

---

## A.5 Success Metrics

### Key Performance Indicators

| KPI | Current | Target | How to Measure |
|-----|---------|--------|----------------|
| Mean Time to Detect (MTTD) | Unknown (hours?) | < 5 min | Time from issue to alert |
| Mean Time to Resolve (MTTR) | Unknown | < 30 min | Time from alert to fix |
| Visibility coverage | 0% | 100% | Services with metrics/logs |
| Alert noise | N/A | < 5/week | False positive alerts |
| Dashboard usage | 0 | Daily | Grafana login frequency |

### Definition of Done

- [ ] All 4 VMs sending metrics to central dashboard
- [ ] All containers sending logs to central log store
- [ ] Uptime checks running for all public endpoints
- [ ] Alerts firing to ntfy on service down
- [ ] Grafana dashboard showing health overview

---

# Part B: What We Need to Build It

---

## B.1 Architecture Overview

### Target Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              VISUALIZATION                                │
│                          ┌─────────────────┐                              │
│                          │    Grafana      │                              │
│                          │  (dashboards)   │                              │
│                          └────────┬────────┘                              │
├───────────────────────────────────┼──────────────────────────────────────┤
│                              STORAGE                                      │
│      ┌─────────────┐    ┌─────────┴────────┐    ┌─────────────┐          │
│      │VictoriaM    │    │      Loki        │    │   Tempo     │          │
│      │ (metrics)   │    │     (logs)       │    │  (traces)   │          │
│      └──────▲──────┘    └────────▲─────────┘    └──────▲──────┘          │
├─────────────┼────────────────────┼─────────────────────┼─────────────────┤
│                              COLLECTION                                   │
│             │                    │                     │                  │
│      ┌──────┴──────┐    ┌────────┴────────┐    ┌──────┴──────┐          │
│      │ node_export │    │    Promtail     │    │   OTel      │          │
│      │ (scrape)    │    │  (ship logs)    │    │ (optional)  │          │
│      └──────▲──────┘    └────────▲────────┘    └──────▲──────┘          │
├─────────────┼────────────────────┼─────────────────────┼─────────────────┤
│                              SOURCES                                      │
│      ┌──────┴──────┐    ┌────────┴────────┐    ┌──────┴──────┐          │
│      │  Host OS    │    │  Docker Logs    │    │   Apps      │          │
│      │ /proc, /sys │    │  /var/lib/docker│    │ (instrumented)        │
│      └─────────────┘    └─────────────────┘    └─────────────┘          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Deployment Strategy

| Component | Deployed On | Reason |
|-----------|-------------|--------|
| Grafana | gcp-micro-1 | Central, always-on |
| VictoriaMetrics | gcp-micro-1 | Low RAM, central |
| Loki | gcp-micro-1 | Pairs with Grafana |
| Promtail | Each VM | Ships logs locally |
| node_exporter | Each VM | Exposes metrics |
| Uptime Kuma | gcp-micro-1 | Endpoint monitoring |
| Alertmanager | gcp-micro-1 | Alert routing |

---

## B.2 Knowledge Forms & Data Model

### Two Data Types, Three Knowledge Forms

```
        RAW DATA                    KNOWLEDGE FORM
        ────────                    ──────────────

   ┌──────────────┐            ┌─────────────────────┐
   │   Numbers    │  ────────▶ │  CALCULATE          │
   │  (metrics)   │            │  trends, thresholds │
   └──────────────┘            │  "CPU avg = 73%"    │
                               └─────────────────────┘

   ┌──────────────┐            ┌─────────────────────┐
   │    Text      │  ────────▶ │  READ               │
   │   (logs)     │            │  events, errors     │
   └──────────────┘            │  "DB timeout at 3pm"│
                               └─────────────────────┘

   ┌──────────────┐            ┌─────────────────────┐
   │    Text      │  ────────▶ │  RELATE             │
   │  (traces)    │            │  causality, flow    │
   └──────────────┘            │  "API→DB→Cache=slow"│
                               └─────────────────────┘
```

### Database Selection by Knowledge Form

| Knowledge Form | Data Type | Query Pattern | DB Type | Selection |
|----------------|-----------|---------------|---------|-----------|
| **Calculate** | Numeric | `SUM`, `AVG`, `RATE` | TSDB | VictoriaMetrics |
| **Read** | Text | `GREP`, `FILTER`, `SEARCH` | Log DB | Loki |
| **Relate** | Text (structured) | `TRACE_ID → spans[]` | Trace DB | Tempo (Phase 2) |

### Pillars by Knowledge Form

```
┌─────────────────────────────────────────────────────────────┐
│                     OBSERVABILITY                            │
├───────────────────┬───────────────────┬─────────────────────┤
│     CALCULATE     │       READ        │       RELATE        │
│    (Numbers)      │      (Text)       │    (Connections)    │
├───────────────────┼───────────────────┼─────────────────────┤
│ • Metrics         │ • Logs            │ • Traces            │
│ • Uptime checks   │ • Auth events     │ • APM spans         │
│ • Cost data       │ • Firewall logs   │ • Dependency maps   │
│ • Network stats   │ • SIEM alerts     │ • Request flows     │
├───────────────────┼───────────────────┼─────────────────────┤
│ TSDB              │ Log DB            │ Trace DB            │
│ VictoriaMetrics   │ Loki              │ Tempo               │
└───────────────────┴───────────────────┴─────────────────────┘
```

---

## B.3 Technology Stack

### Tool Selection

| Category | Pillar | Tool | Alternatives | RAM | Custom (Rust) | Rust RAM |
|----------|--------|------|--------------|-----|---------------|----------|
| **HEALTH** | Metrics | VictoriaMetrics | Prometheus | 256MB | tsdb-lite | ~32MB |
| | Logs | Loki + Promtail | Elasticsearch | 256MB | log-collector | ~16MB |
| | Traces | Tempo | Jaeger | 128MB | trace-store | ~24MB |
| | Profiling | Pyroscope | Parca | 256MB | - | - |
| | APM | OpenTelemetry | SigNoz | 128MB | otel-receiver | ~16MB |
| | Uptime | Uptime Kuma | Gatus | 64MB | probe-daemon | ~8MB |
| **SECURITY** | SIEM | Wazuh Agent | - | 256MB | siem-lite | ~32MB |
| | Network | Netdata | ntopng | 128MB | net-monitor | ~16MB |
| | Firewall | Fail2ban + UFW logs | - | 32MB | fw-watcher | ~4MB |
| | Auth | Authelia logs → Loki | - | 0MB | (use log-collector) | 0MB |
| **OPERATIONS** | Incidents | Grafana OnCall | - | 128MB | - | - |
| | Chaos | - | Chaos Mesh | - | chaos-runner | ~8MB |
| | Cost | Custom scripts | OpenCost | 0MB | cost-tracker | ~4MB |
| | Docs | Obsidian | Wiki | 0MB | - | - |
| **CORE** | Visualization | Grafana | - | 256MB | - (use Grafana) | - |
| | Alerts | Alertmanager → ntfy | - | 64MB | alert-router | ~8MB |

### RAM Comparison

| Stack | Components | Total RAM |
|-------|------------|-----------|
| **Standard (Go/Node)** | VictoriaMetrics + Loki + Grafana + Uptime Kuma + Alertmanager | ~896MB |
| **Custom (Rust)** | tsdb-lite + log-collector + probe-daemon + alert-router + Grafana | ~320MB |
| **Savings** | | **~576MB (64%)** |

### Pillar Reference

| Pillar | Question | Description |
|--------|----------|-------------|
| Metrics | How much? How fast? | Time-series data (CPU %, RAM, req/sec). Numeric values over time. |
| Logs | What happened? When? | Text event streams. Searchable history of events. |
| Traces | Where is it slow? | Request journey across services. Latency per hop. |
| Profiling | Why is it slow? (code) | Code-level CPU/memory analysis. Flame graphs. |
| APM | Is the app healthy? | Error rates, response times, dependency maps. |
| Uptime | Is it reachable? | HTTP/TCP probes with status pages and alerts. |
| SIEM | Am I being attacked? | Security log correlation. Brute force, anomalies. |
| Network | Who talks to whom? | Bandwidth, connections, packet loss, DDoS. |
| Firewall | Who got blocked? | Auto-blocks IPs, tracks allowed/denied. |
| Auth | Who logged in? | Logins, 2FA, session management. |
| Incidents | Who fixes it? How? | On-call, escalation, postmortems, runbooks. |
| Chaos | Will it survive failure? | Kill pods, add latency, fill disks. |
| Cost | Am I overspending? | CPU-hours, RAM-GB-hours, storage costs. |
| Docs/Runbooks | How do I fix this? | Troubleshooting guides, playbooks. |

---

## B.4 Pillar Specifications

### B4.1 Metrics

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Calculate (Numeric) |
| **Question** | How much? How fast? |
| **Tool** | VictoriaMetrics |
| **Collector** | node_exporter, cAdvisor |
| **RAM** | 256MB |
| **Storage** | ~1GB/month |
| **Retention** | 90 days |

**Data Sources:**
- Host: CPU, RAM, disk, network (node_exporter)
- Containers: CPU, RAM, restarts (cAdvisor)
- Custom: Flask API metrics (prometheus_client)

**Key Metrics:**
```
node_cpu_seconds_total
node_memory_MemAvailable_bytes
node_filesystem_avail_bytes
container_cpu_usage_seconds_total
container_memory_usage_bytes
```

**Alerts:**
| Alert | Condition | Severity |
|-------|-----------|----------|
| HighCPU | cpu > 90% for 5m | warning |
| HighMemory | mem > 85% for 5m | warning |
| DiskFull | disk > 90% | critical |
| ContainerDown | up == 0 for 2m | critical |

---

### B4.2 Logs

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Read (Text) |
| **Question** | What happened? When? |
| **Tool** | Loki |
| **Collector** | Promtail |
| **RAM** | 256MB |
| **Storage** | ~5GB/month |
| **Retention** | 30 days |

**Data Sources:**
- Docker container logs (/var/lib/docker/containers)
- Syslog (/var/log/syslog)
- Auth logs (/var/log/auth.log)
- Application logs (stdout/stderr)

**Labels:**
```yaml
job: docker
container: nginx
host: gcp-micro-1
level: error|warn|info
```

**Queries:**
```logql
{container="flask-api"} |= "error"
{host="gcp-micro-1"} | json | level="error"
rate({job="docker"}[5m])
```

---

### B4.3 Traces

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Relate (Connections) |
| **Question** | Where is it slow? |
| **Tool** | Tempo |
| **Collector** | OpenTelemetry SDK |
| **RAM** | 128MB |
| **Storage** | ~2GB/month |
| **Retention** | 7 days |
| **Phase** | Phase 2 |

**Data Flow:**
```
App (instrumented) → OTel Collector → Tempo → Grafana
```

**Span Example:**
```json
{
  "traceId": "abc123",
  "spanId": "span1",
  "operationName": "GET /api/status",
  "duration": 150,
  "tags": {
    "http.status_code": 200,
    "service.name": "flask-api"
  }
}
```

---

### B4.4 Profiling

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Relate (Code-level) |
| **Question** | Why is it slow? (code) |
| **Tool** | Pyroscope |
| **RAM** | 256MB |
| **Phase** | Phase 2 |

**Output:** Flame graphs showing function-level CPU/memory usage.

---

### B4.5 APM

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Calculate + Read + Relate |
| **Question** | Is the app healthy? |
| **Tool** | OpenTelemetry + Grafana |
| **RAM** | 128MB |
| **Phase** | Phase 2 |

**Combines:** Metrics + Logs + Traces into unified app view.

---

### B4.6 Uptime

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Calculate (Numeric) |
| **Question** | Is it reachable? |
| **Tool** | Uptime Kuma |
| **RAM** | 64MB |
| **Storage** | Minimal |

**Endpoints to Monitor:**

| Endpoint | Type | Interval |
|----------|------|----------|
| https://api.diegonmarcos.com | HTTP 200 | 60s |
| https://analytics.diegonmarcos.com | HTTP 200 | 60s |
| https://mail.diegonmarcos.com | HTTP 200 | 60s |
| https://photos.app.diegonmarcos.com | HTTP 200 | 300s |
| https://auth.diegonmarcos.com | HTTP 200 | 60s |

**Alerts:** → ntfy on down > 2 checks

---

### B4.7 SIEM

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Read + Relate |
| **Question** | Am I being attacked? |
| **Tool** | Wazuh Agent → Loki |
| **RAM** | 256MB |
| **Phase** | Phase 2 |

**Detects:**
- Brute force SSH attempts
- Suspicious file changes
- Rootkit detection
- Compliance violations

---

### B4.8 Network

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Calculate + Relate |
| **Question** | Who talks to whom? |
| **Tool** | Netdata / node_exporter |
| **RAM** | 128MB |
| **Phase** | Phase 2 |

**Metrics:**
- Bandwidth per interface
- Connections per container
- Packet loss
- Latency between VMs

---

### B4.9 Firewall

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Read (Access logs) |
| **Question** | Who got blocked? |
| **Tool** | Fail2ban + UFW logs → Loki |
| **RAM** | 32MB |

**Log Sources:**
- /var/log/ufw.log
- /var/log/fail2ban.log

**Alerts:**
| Alert | Condition |
|-------|-----------|
| BruteForce | > 10 blocks from same IP in 5m |
| NewBlockedCountry | Block from never-seen country |

---

### B4.10 Auth

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Read (Identity events) |
| **Question** | Who logged in? |
| **Tool** | Authelia logs → Loki |
| **RAM** | 0MB (uses existing) |

**Events:**
- Successful logins
- Failed login attempts
- 2FA challenges
- Session creation/destruction

---

### B4.11 Incidents

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Process (Workflow) |
| **Question** | Who fixes it? How? |
| **Tool** | Grafana OnCall / Manual |
| **Phase** | Phase 3 |

**Components:**
- On-call schedule (solo dev = always on-call)
- Escalation policy
- Runbooks in Obsidian
- Postmortem templates

---

### B4.12 Chaos

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Process (Testing) |
| **Question** | Will it survive failure? |
| **Tool** | Manual / Scripts |
| **Phase** | Phase 3 |

**Tests:**
- Kill random container
- Fill disk to 95%
- Add 500ms network latency
- Block external DNS

---

### B4.13 Cost

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Calculate (Financial) |
| **Question** | Am I overspending? |
| **Tool** | Custom dashboard |
| **RAM** | 0MB |

**Tracked:**
- OCI flex-1 usage hours ($5.50/month)
- GCP egress bandwidth
- Storage growth rate

---

### B4.14 Docs/Runbooks

| Attribute | Value |
|-----------|-------|
| **Knowledge Form** | Read (Reference) |
| **Question** | How do I fix this? |
| **Tool** | Obsidian / This repo |

**Contents:**
- Architecture diagrams
- Runbooks per service
- Incident playbooks
- CLAUDE.md for AI context

---

## B.5 Implementation Phases

### Phase 1: Foundation (MVP)

| Task | Tool | VM | RAM |
|------|------|-----|-----|
| Install VictoriaMetrics | VM | gcp-micro-1 | 256MB |
| Install Grafana | VM | gcp-micro-1 | 256MB |
| Install node_exporter | All | all 4 VMs | 32MB each |
| Install Loki | VM | gcp-micro-1 | 256MB |
| Install Promtail | All | all 4 VMs | 64MB each |
| Install Uptime Kuma | VM | gcp-micro-1 | 64MB |
| Configure Alertmanager | VM | gcp-micro-1 | 64MB |
| Connect alerts to ntfy | Config | gcp-micro-1 | 0 |

**RAM Budget (gcp-micro-1):** 256+256+256+64+64 = **896MB** ✓

### Phase 2: Security & Depth

| Task | Tool |
|------|------|
| Add Fail2ban logging | Promtail config |
| Add Authelia log parsing | Promtail config |
| Install Tempo (traces) | gcp-micro-1 |
| Instrument Flask API | OpenTelemetry |
| Add Wazuh agent | all VMs |

### Phase 3: Operations

| Task | Tool |
|------|------|
| Create runbooks | Obsidian |
| Setup incident workflow | Grafana OnCall |
| Cost tracking dashboard | Grafana |
| Chaos testing scripts | Bash |

---

## Appendix: Quick Reference

### Docker Compose (gcp-micro-1)

```yaml
# To be created during Phase 1
services:
  victoriametrics:
    image: victoriametrics/victoria-metrics
    ports: ["8428:8428"]
    volumes: ["./vm-data:/victoria-metrics-data"]

  grafana:
    image: grafana/grafana
    ports: ["3000:3000"]
    volumes: ["./grafana-data:/var/lib/grafana"]

  loki:
    image: grafana/loki
    ports: ["3100:3100"]
    volumes: ["./loki-data:/loki"]

  uptime-kuma:
    image: louislam/uptime-kuma
    ports: ["3001:3001"]
    volumes: ["./uptime-data:/app/data"]
```

### Endpoints After Deployment

| Service | URL |
|---------|-----|
| Grafana | https://grafana.diegonmarcos.com |
| Uptime Kuma | https://status.diegonmarcos.com |
| VictoriaMetrics | Internal :8428 |
| Loki | Internal :3100 |
