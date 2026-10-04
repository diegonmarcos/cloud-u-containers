# Sauron Security Stack

File integrity monitoring + YARA malware scanning for all VMs.

## Architecture

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  oci-web1    │  │  oci-svc1    │  │  gcp-arch1   │
│              │  │              │  │              │
│ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │
│ │ Sauron   │ │  │ │ Sauron   │ │  │ │ Sauron   │ │
│ │ YARA     │ │  │ │ YARA     │ │  │ │ YARA     │ │
│ └────┬─────┘ │  │ └────┬─────┘ │  │ └────┬─────┘ │
│      │       │  │      │       │  │      │       │
│ ┌────▼─────┐ │  │ ┌────▼─────┐ │  │ ┌────▼─────┐ │
│ │syslog-ng │ │  │ │syslog-ng │ │  │ │syslog-ng │ │
│ └────┬─────┘ │  │ └────┬─────┘ │  │ └────┬─────┘ │
└──────┼───────┘  └──────┼───────┘  └──────┼───────┘
       │                 │                 │
       └────────────────┼─────────────────┘
                        │ TCP:5514
                        ▼
              ┌─────────────────┐
              │  GCP Central    │
              │  syslog-ng      │
              │  SQLite SIEM    │
              │  REST API       │
              └─────────────────┘
```

## Quick Start

### 1. Deploy Central Collector (GCP)

```bash
cd central/
docker compose up -d
```

### 2. Deploy to All VMs

```bash
./scripts/deploy.sh deploy
```

### 3. Check Status

```bash
./scripts/deploy.sh status
```

## Directory Structure

```
sauron/
├── docker-compose.yml      # VM deployment (Sauron + syslog-ng)
├── Dockerfile.sauron       # Sauron container build
├── config/
│   ├── sauron.yml          # Sauron configuration
│   └── syslog-ng.conf      # Log forwarding config
├── yara-rules/
│   └── custom/
│       ├── webshells.yar   # Webshell detection
│       ├── cryptominers.yar # Miner detection
│       └── suspicious.yar  # Reverse shells, creds
├── scripts/
│   └── deploy.sh           # Deployment automation
└── central/
    ├── docker-compose.yml  # Central collector
    ├── syslog-ng-central.conf
    ├── Dockerfile.api
    └── api/
        └── app.py          # Simple SIEM REST API
```

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/deploy.sh deploy` | Deploy to all VMs |
| `./scripts/deploy.sh deploy oci-web1` | Deploy to specific VM |
| `./scripts/deploy.sh status` | Check container status |
| `./scripts/deploy.sh logs` | View logs |
| `./scripts/deploy.sh restart` | Restart containers |
| `./scripts/deploy.sh update-rules` | Push new YARA rules |

## API Endpoints (Central)

| Endpoint | Description |
|----------|-------------|
| `GET /api/health` | Health check |
| `GET /api/alerts` | List alerts (supports ?vm=, ?severity=, ?limit=) |
| `GET /api/stats` | Alert statistics |
| `GET /api/vms` | List VMs with alert counts |

## RAM Usage

| Component | RAM |
|-----------|-----|
| Sauron | ~10 MB |
| syslog-ng | ~20 MB |
| **Total per VM** | **~30 MB** |

## Adding YARA Rules

1. Add `.yar` files to `yara-rules/custom/`
2. Run `./scripts/deploy.sh update-rules`

## Querying Alerts

```bash
# Using API
curl http://localhost:8080/api/alerts?severity=high

# Using jq on JSONL
cat /var/log/siem/alerts.jsonl | jq 'select(.alert.severity == "critical")'

# Using DuckDB
duckdb -c "SELECT * FROM read_json_auto('/var/log/siem/alerts.jsonl') WHERE alert.severity = 'critical'"
```
