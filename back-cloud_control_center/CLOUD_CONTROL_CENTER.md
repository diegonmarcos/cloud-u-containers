# Cloud Control Center

Check categories for cloud infrastructure monitoring.

**Total: 44 checks across 8 categories**

---

## 1. Availability (Is it up?)

| Check | What | Method | Alert |
|-------|------|--------|-------|
| Ping | VM reachable | ICMP | Down > 30s |
| SSH | Can connect | TCP :22 | Connection refused |
| HTTP | Endpoints responding | GET /health → 200 | Non-200 |
| SSL | Certificates valid | Cert expiry check | < 14 days |
| DNS | Resolving correctly | nslookup | Resolution fail |
| Ports | Services listening | TCP check | Port closed |

---

## 2. Performance (How is it running?)

| Check | What | Threshold | Alert |
|-------|------|-----------|-------|
| CPU | Usage % | < 80% | > 80% sustained |
| RAM | Usage % | < 85% | > 85% |
| Disk | Space & I/O | < 90% | > 90% |
| Network | Bandwidth & latency | < 80% capacity | Saturation |
| Load | System load average | < 2.0 | > 2.0 |
| Response time | API/page latency | < 200ms | > 500ms |

---

## 3. Security (Any threats?)

| Check | What | Method | Alert |
|-------|------|--------|-------|
| Failed SSH | Brute force attempts | auth.log parse | > 5/min |
| Firewall | Blocked connections | iptables/ufw logs | Spike |
| Auth logs | Unauthorized access | PAM, sudo logs | Any failure |
| File integrity | System file changes | find /etc -mtime | Unexpected |
| CVE/Patches | Outdated packages | apt/yum check | Critical/High |
| Open ports | Unexpected services | ss -tlnp | New port |

---

## 4. Costs (How much?)

| Check | What | Source | Alert |
|-------|------|--------|-------|
| Cloud billing | GCP, OCI spend | Billing API | > budget |
| Resource usage | Over/under provisioned | Metrics | Waste detected |
| AI costs | Claude, API usage | Token logs | > daily limit |
| Trends | Month-over-month | Historical | +20% increase |

---

## 5. Docker/Services (Apps healthy?)

| Check | What | Method | Alert |
|-------|------|--------|-------|
| Container status | Running/stopped | docker ps | Stopped |
| Container health | Healthcheck pass | docker inspect | Unhealthy |
| Restarts | Crash loops | RestartCount | > 3 |
| Logs | Errors/warnings | docker logs | ERROR/FATAL |
| Resources | Per-container CPU/RAM | docker stats | > limits |

---

## 6. Backups/Data

| Check | What | Method | Alert |
|-------|------|--------|-------|
| Backup status | Last successful | Timestamp check | > 24h old |
| Backup size | Growing normally | Size comparison | Shrunk/stale |
| Restore test | Can recover | Periodic test | Failure |
| Sync status | Syncthing healthy | API/logs | Out of sync |

---

## 7. Web/HTTP (Traffic analysis)

| Check | What | Method | Alert |
|-------|------|--------|-------|
| Access logs | Request patterns | NPM logs | Anomaly |
| Error rates | 4xx/5xx | Log parse | > 5% |
| Suspicious requests | SQLi, XSS, traversal | Pattern match | Any match |
| Top IPs | Traffic sources | Log aggregation | Abuse |
| Scanner agents | Bots, nikto, sqlmap | User-agent | Detected |
| Response codes | Distribution | Log stats | 5xx spike |

---

## 8. Architecture (Infrastructure map)

**Source:** `/home/diego/Documents/Git/back-System/cloud/0.spec/architecture.json`

| Check | What | Source |
|-------|------|--------|
| Providers | GCP, OCI config | architecture.json |
| VM inventory | IPs, specs, categories | architecture.json |
| Services | Apps, ports, URLs | architecture.json |
| Networks | VPN, Docker subnets | architecture.json |
| Domains | DNS mappings | architecture.json |
| Costs | Per-VM/service costs | architecture.json |
| SSH commands | Access credentials | architecture.json |

---

## Implementation

| # | Category | In-house | External |
|---|----------|----------|----------|
| 0 | Availability | `0.availability.py` | Uptime Kuma |
| 0 | Performance | `0.performance.py` | Netdata |
| 1 | Docker | `1.docker.py` | Netdata |
| 2 | Security | `2.security.py` | - |
| 2 | Backups | `2.backups.py` | - |
| 2 | Web/HTTP | `2.web.py` | - |
| 3 | Costs | `3.costs.py` | - |
| 4 | Architecture | `4.architecture.py` | - |

---

## Tool Coverage

| Category | Kuma | Netdata | Dozzle | In-house |
|----------|:----:|:-------:|:------:|:--------:|
| Availability | ✅ | - | - | ✅ |
| Performance | - | ✅ | - | ✅ |
| Docker | - | ✅ | logs | ✅ |
| Security | - | - | - | ✅ |
| Backups | - | - | - | ✅ |
| Web/HTTP | - | - | - | ✅ |
| Costs | - | - | - | ✅ |
| Architecture | - | - | - | ✅ |

**kuma-netdata/in-house/** symlinks fill gaps that external tools don't cover.

---

## Folder Structure

```
c3/
├── CLOUD_CONTROL_CENTER.md
├── in-house/
│   ├── main.py                 # Runner: collect | convert | all
│   ├── 1.collectors/           # Collect raw data from VMs
│   │   ├── 0.availability.py
│   │   ├── 0.performance.py
│   │   ├── 1.docker.py
│   │   ├── 2.security.py
│   │   ├── 2.backups.py
│   │   ├── 2.web.py
│   │   ├── 3.costs.py
│   │   └── 4.architecture.py
│   ├── 2.raw/                  # Raw collected data
│   │   ├── availability/YYYY-MM-DD/
│   │   ├── performance/YYYY-MM-DD/
│   │   ├── security/YYYY-MM-DD/
│   │   ├── costs/YYYY-MM/
│   │   ├── docker/YYYY-MM-DD/
│   │   ├── backups/YYYY-MM-DD/
│   │   ├── web/YYYY-MM-DD/
│   │   └── architecture/YYYY-MM-DD/
│   ├── 3.converters/           # Convert raw → JSON
│   │   └── to_json.py
│   └── 4.jsons/                # Clean JSON for API
│       ├── dashboard.json
│       ├── availability.json
│       ├── performance.json
│       ├── security.json
│       ├── costs.json
│       ├── docker.json
│       ├── backups.json
│       ├── web.json
│       └── architecture.json
└── kuma-netdata/               # External tools + in-house gaps
    ├── kuma/                   # Uptime Kuma config
    ├── netdata/                # Netdata config
    ├── dozzle/                 # Docker log viewer
    │   └── docker-compose.yml
    └── in-house/               # Scripts for what Kuma+Netdata don't cover
        ├── 2.security.py → ../../in-house/1.collectors/2.security.py
        ├── 2.backups.py → ../../in-house/1.collectors/2.backups.py
        ├── 2.web.py → ../../in-house/1.collectors/2.web.py
        ├── 3.costs.py → ../../in-house/1.collectors/3.costs.py
        └── 4.architecture.py → ../../in-house/1.collectors/4.architecture.py
```

---

## Usage

```bash
# Run everything
python main.py

# Only collect
python main.py collect

# Only convert
python main.py convert
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   CLOUD CONTROL CENTER                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │  In-house    │  │  Uptime Kuma │  │   Netdata    │       │
│  │  Python      │  │  (Avail)     │  │  (Perf)      │       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
│         │                 │                 │                │
│         └─────────────────┴─────────────────┘                │
│                           │                                  │
│                    ┌──────▼───────┐                          │
│                    │   Dashboard  │                          │
│                    │   (API/JSON) │                          │
│                    └──────────────┘                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Pipeline

```
1. Collectors    →    2. Raw    →    3. Converters    →    4. JSONs    →    API
   (SSH/gcloud)       (files)        (parse/clean)         (structured)     (/api/audit/*)
```
