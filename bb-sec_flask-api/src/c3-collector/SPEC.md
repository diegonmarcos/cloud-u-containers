# In-House Cloud Monitor - Specification

> **Version**: 1.1
> **Updated**: 2025-12-15
> **Location**: `/home/diego/Documents/Git/back-System/cloud/a_solutions/c3/in-house/`

---

## 1. Overview

Lightweight monitoring solution that collects infrastructure metrics and outputs structured JSON for dashboard consumption.

### Source of Truth

```
/home/diego/Documents/Git/back-System/cloud/0.spec/architecture.json
```

All collectors read VM IPs, SSH commands, endpoints, and services from this file via `config.py`.

### Pipeline

```
architecture.json ──► config.py ──► collectors ──► 2.raw/ ──► converters ──► 4.jsons/
     (source)         (loader)      (collect)     (store)     (parse)       (API)
```

---

## 2. Collector Hierarchy

```
1.collectors/
├── config.py              # Loads architecture.json (shared by all)
│
├── 0. ORCHESTRATE (Infrastructure foundation)
│   ├── 0.architecture.py  # Full infra topology from architecture.json
│   └── 0.docker.py        # Container inventory & status per VM
│
├── 1. MONITOR (Health checks)
│   ├── 1.availability.py  # Is it up? (ping, HTTP, SSL, DNS)
│   └── 1.performance.py   # How is it running? (CPU, RAM, disk, load)
│
├── 2. SECURITY (Threats & protection)
│   ├── 2.security.py      # Failed SSH, open ports, auth logs
│   ├── 2.backups.py       # Backup status, sync health
│   └── 2.web.py           # NPM logs, error rates, suspicious requests
│
└── 3. COST (Spending)
    ├── 3.cost_infra.py    # GCP/OCI billing
    └── 3.cost_ai.py       # Claude token usage
```

---

## 3. Directory Structure

```
in-house/
├── main.py                     # Orchestrator: collect | convert | all
├── SPEC.md                     # This file
│
├── 1.collectors/               # Data collection scripts
│   ├── config.py               # Loads from architecture.json
│   ├── 0.architecture.py       # Infrastructure topology
│   ├── 0.docker.py             # Container status
│   ├── 1.availability.py       # Uptime, HTTP, SSL
│   ├── 1.performance.py        # CPU, RAM, disk
│   ├── 2.security.py           # SSH attacks, ports
│   ├── 2.backups.py            # Backup status
│   ├── 2.web.py                # HTTP traffic analysis
│   ├── 3.cost_infra.py         # Cloud billing
│   └── 3.cost_ai.py            # AI token costs
│
├── 2.raw/                      # Raw collected data (date-organized)
│   ├── architecture/YYYY-MM-DD/
│   ├── docker/YYYY-MM-DD/
│   ├── availability/YYYY-MM-DD/
│   ├── performance/YYYY-MM-DD/
│   ├── security/YYYY-MM-DD/
│   ├── backups/YYYY-MM-DD/
│   ├── web/YYYY-MM-DD/
│   └── costs/YYYY-MM/          # Monthly for costs
│
├── 3.converters/               # Raw → JSON converters
│   └── to_json.py
│
├── 4.jsons/                    # API-ready output
│   ├── dashboard.json          # Aggregated summary + alerts
│   ├── architecture.json
│   ├── docker.json
│   ├── availability.json
│   ├── performance.json
│   ├── security.json
│   ├── backups.json
│   ├── web.json
│   └── costs.json
│
└── 5.front_monitor/            # Dashboard UI
```

---

## 4. config.py - Architecture Loader

All collectors import `config.py` to access the architecture:

```python
from config import (
    get_active_vms,      # {vm_id: vm_config}
    get_vm,              # Single VM config
    get_vm_ip,           # IP for a VM
    get_ssh_command,     # SSH command list for subprocess
    get_endpoints,       # URLs to monitor
    get_ssl_domains,     # Domains for SSL check
    get_services,        # All services
    get_costs,           # Cost configuration
    RAW_DIR,             # Path to 2.raw/
    JSON_DIR,            # Path to 4.jsons/
)
```

### Example Usage in Collector

```python
#!/usr/bin/env python3
from config import get_active_vms, get_ssh_command, RAW_DIR
import subprocess
import json
from datetime import datetime

DATE = datetime.now().strftime("%Y-%m-%d")

def collect_all():
    results = {"timestamp": datetime.now().isoformat(), "vms": {}}

    for vm_id, vm in get_active_vms().items():
        cmd = get_ssh_command(vm_id, "uptime")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        results["vms"][vm_id] = {"uptime": result.stdout}

    return results

def save_raw(data, category="example"):
    output_dir = RAW_DIR / category / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"{category}_{datetime.now().strftime('%H')}00.json"
    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"Saved: {output_file}")

if __name__ == "__main__":
    save_raw(collect_all())
```

---

## 5. Collector Specifications

### 0. ORCHESTRATE

#### 0.architecture.py

**Purpose**: Export full infrastructure topology from `architecture.json`

**Output**: `2.raw/architecture/YYYY-MM-DD/architecture_HH00.json`

**Contents**:
- All VMs (IPs, specs, SSH commands)
- All services (URLs, ports, status)
- All domains/subdomains
- Docker networks per VM
- Firewall rules
- Cost breakdown

---

#### 0.docker.py

**Purpose**: Container inventory and status per VM

**Collects via SSH**:
```bash
docker ps --format json
docker stats --no-stream --format json
docker inspect --format '{{.State.Health.Status}}' <container>
```

**Output Schema**:
```json
{
  "timestamp": "ISO8601",
  "vms": {
    "gcp-f-micro_1": {
      "containers": [
        {"name": "npm", "status": "running", "cpu": "0.5%", "mem": "128MB"}
      ]
    }
  }
}
```

---

### 1. MONITOR

#### 1.availability.py

**Purpose**: Is it up?

**Checks**:
| Check | Method | Alert Threshold |
|-------|--------|-----------------|
| Ping | ICMP | Down > 30s |
| SSH | TCP :22 | Connection refused |
| HTTP | GET /health | Non-200 |
| SSL | Cert expiry | < 14 days |
| DNS | nslookup | Resolution fail |

**Output Schema**:
```json
{
  "timestamp": "ISO8601",
  "vms": {
    "<vm_id>": {
      "ping": {"status": "up", "latency_ms": 12.5},
      "ssh": {"status": "ok"}
    }
  },
  "endpoints": [
    {"url": "https://...", "status": "up", "code": 200, "latency_ms": 150}
  ],
  "ssl": [
    {"domain": "...", "status": "ok", "days_left": 45}
  ]
}
```

---

#### 1.performance.py

**Purpose**: How is it running?

**Checks**:
| Check | Command | Alert Threshold |
|-------|---------|-----------------|
| CPU | `top -bn1` | > 80% sustained |
| RAM | `free -m` | > 85% |
| Disk | `df -h` | > 90% |
| Load | `uptime` | > 2.0 |

**Output Schema**:
```json
{
  "timestamp": "ISO8601",
  "vms": {
    "<vm_id>": {
      "load_1m": 0.5,
      "memory": {"total_mb": 1024, "used_mb": 512, "percent": 50},
      "disk": [{"mount": "/", "percent": 45}]
    }
  }
}
```

---

### 2. SECURITY

#### 2.security.py

**Purpose**: Detect threats

**Checks**:
| Check | Source | Alert |
|-------|--------|-------|
| Failed SSH | auth.log | > 5/min from IP |
| Open ports | `ss -tlnp` | Unexpected port |
| Auth failures | PAM/sudo logs | Any failure |

---

#### 2.backups.py

**Purpose**: Verify backup integrity

**Checks**:
- Syncthing API status
- Last backup timestamp
- Backup size (growth/shrink)

---

#### 2.web.py

**Purpose**: HTTP traffic analysis

**Checks**:
| Check | Source | Alert |
|-------|--------|-------|
| Top IPs | NPM access logs | Abuse pattern |
| Error rates | 4xx/5xx | > 5% |
| Suspicious | SQLi/XSS patterns | Any match |
| Scanners | User-agent | nikto/sqlmap |

---

### 3. COST

#### 3.cost_infra.py

**Purpose**: Cloud billing

**Sources**:
- `gcloud billing accounts list`
- `oci iam tenancy get`
- architecture.json costs section

**Output**:
```json
{
  "gcp": {"status": "ok", "tier": "free"},
  "oci": {"status": "ok", "tier": "always-free"},
  "paid_vms": {"oci-p-flex_1": {"monthly": 5.5}}
}
```

---

#### 3.cost_ai.py

**Purpose**: Claude token usage

**Source**: `~/.claude/projects/*.jsonl`

**Output**:
```json
{
  "today": {"input": 50000, "output": 10000},
  "week": {"input": 350000, "output": 70000},
  "month": {"input": 1500000, "output": 300000},
  "estimated_cost_usd": 12.50
}
```

---

## 6. Converter (to_json.py)

Reads `2.raw/`, generates clean JSON in `4.jsons/`.

**Alert Generation**:
| Condition | Level |
|-----------|-------|
| VM unreachable | critical |
| SSL < 7 days | critical |
| SSL < 14 days | warning |
| Memory > 90% | critical |
| Disk > 90% | critical |
| Load > 2.0 | warning |
| SSH attacks > 100/IP | warning |
| Container unhealthy | warning |

**Dashboard aggregates all alerts** sorted by severity.

---

## 7. Usage

```bash
cd /home/diego/Documents/Git/back-System/cloud/a_solutions/c3/in-house

# Run everything
python main.py

# Only collectors
python main.py collect

# Only converters
python main.py convert

# Single collector
python 1.collectors/0.architecture.py

# Test config loader
python 1.collectors/config.py
```

---

## 8. Scheduling (Cron)

```cron
# Orchestrate - hourly
0 * * * * python 1.collectors/0.architecture.py
0 * * * * python 1.collectors/0.docker.py

# Monitor - every 5 min
*/5 * * * * python 1.collectors/1.availability.py
*/15 * * * * python 1.collectors/1.performance.py

# Security - hourly
0 * * * * python 1.collectors/2.security.py
0 * * * * python 1.collectors/2.web.py
0 */6 * * * python 1.collectors/2.backups.py

# Cost - daily
0 0 * * * python 1.collectors/3.cost_infra.py
0 0 * * * python 1.collectors/3.cost_ai.py

# Convert - every 15 min
*/15 * * * * python 3.converters/to_json.py
```

---

## 9. Architecture.json Reference

The collectors read these sections:

| Section | Used By |
|---------|---------|
| `virtualMachines` | All (VMs, IPs, SSH) |
| `services` | 0.architecture, 0.docker |
| `domains.subdomains` | 1.availability (endpoints, SSL) |
| `quickCommands.ssh` | All collectors |
| `costs` | 3.cost_infra |
| `dockerNetworks` | 0.docker |
| `firewallRules` | 2.security |

---

## 10. API Integration

The C3 `4.jsons/` directory integrates with the Flask API via the `c3.py` blueprint.

### Architecture Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CLOUD CONTROL CENTER (C3)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐                                                        │
│  │ architecture.json│  (Source of Truth)                                    │
│  │ back-System/     │                                                        │
│  │ cloud/0.spec/    │                                                        │
│  └────────┬─────────┘                                                        │
│           │                                                                  │
│           ▼                                                                  │
│  ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐     │
│  │   1.collectors/  │────►│     2.raw/       │────►│  3.converters/   │     │
│  │   (SSH/gcloud)   │     │  (date-organized)│     │   (to_json.py)   │     │
│  └──────────────────┘     └──────────────────┘     └────────┬─────────┘     │
│                                                              │               │
│                                                              ▼               │
│                                                    ┌──────────────────┐     │
│                                                    │    4.jsons/      │     │
│                                                    │  dashboard.json  │     │
│                                                    │  availability.json│    │
│                                                    │  performance.json │    │
│                                                    │  security.json    │    │
│                                                    │  docker.json      │    │
│                                                    │  web.json         │    │
│                                                    │  costs.json       │    │
│                                                    └────────┬─────────┘     │
│                                                              │               │
└──────────────────────────────────────────────────────────────┼───────────────┘
                                                               │
                                            mount/symlink      │
                                                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FLASK API                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐                        ┌──────────────────┐           │
│  │   routes.py      │                        │     c3.py        │           │
│  │  /api/config     │                        │   /api/c3/*      │           │
│  │  /api/vms        │                        │                  │           │
│  │  /api/services   │◄── architecture.json   │  /dashboard      │◄── 4.jsons/│
│  │  /api/cloud_ctrl │                        │  /security       │           │
│  └──────────────────┘                        │  /performance    │           │
│                                              │  /availability   │           │
│                                              │  /web /docker    │           │
│                                              │  /costs          │           │
│                                              └────────┬─────────┘           │
│                                                       │                     │
└───────────────────────────────────────────────────────┼─────────────────────┘
                                                        │
                                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            WEB FRONTEND                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  cloud_control.html ──► data-loader.ts ──► fetch('/api/c3/dashboard')       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### API Endpoints (from c3.py)

| Endpoint | Source File | Description |
|----------|-------------|-------------|
| `GET /api/c3/dashboard` | `dashboard.json` | Aggregated summary + alerts |
| `GET /api/c3/alerts` | `dashboard.json` | All alerts |
| `GET /api/c3/security` | `security.json` | Failed SSH, open ports |
| `GET /api/c3/security/failed-ssh` | `security.json` | SSH attack IPs |
| `GET /api/c3/performance` | `performance.json` | CPU, RAM, disk |
| `GET /api/c3/performance/docker` | `performance.json` | Container stats |
| `GET /api/c3/docker` | `docker.json` | Full container inventory |
| `GET /api/c3/availability` | `availability.json` | VM ping, HTTP, SSL |
| `GET /api/c3/availability/endpoints` | `availability.json` | Endpoint status |
| `GET /api/c3/availability/ssl` | `availability.json` | SSL cert expiry |
| `GET /api/c3/web` | `web.json` | NPM logs, threats |
| `GET /api/c3/web/threats` | `web.json` | Suspicious requests |
| `GET /api/c3/costs` | `costs.json` | All costs data |
| `GET /api/c3/costs/infra` | `costs.json` | Cloud billing |
| `GET /api/c3/costs/ai` | `costs.json` | Claude token usage |
| `GET /api/c3/architecture` | `architecture.json` | Full topology |

### Docker Mount

In `docker-compose.yml`:

```yaml
services:
  flask-api:
    volumes:
      # Mount C3 JSON output
      - ../c3/in-house/4.jsons:/app/c3-data:ro
```

### Test Endpoints

```bash
# Dashboard summary
curl http://34.55.55.234:5000/api/c3/dashboard

# All alerts
curl http://34.55.55.234:5000/api/c3/alerts

# Security
curl http://34.55.55.234:5000/api/c3/security

# Availability status
curl http://34.55.55.234:5000/api/c3/availability/status

# SSL certificates
curl http://34.55.55.234:5000/api/c3/availability/ssl

# Costs
curl http://34.55.55.234:5000/api/c3/costs
```

---

## Revision History

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-15 | 1.0 | Initial specification |
| 2025-12-15 | 1.1 | Reorganized hierarchy (Orchestrate/Monitor/Security/Cost) |
| 2025-12-15 | 1.2 | Added API integration section |
