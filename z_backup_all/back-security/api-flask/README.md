# Cloud Control API

REST API for Cloud Infrastructure monitoring.

**Data Sources:**
1. `architecture.json` - Static infrastructure config (VMs, services, domains)
2. `c3/in-house/4.jsons/` - Dynamic monitoring data from C3 collectors

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       DATA SOURCES                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  architecture.json              C3 In-House (4.jsons/)          │
│  ├── VMs & IPs                  ├── dashboard.json              │
│  ├── Services & URLs            ├── availability.json           │
│  ├── Domains                    ├── performance.json            │
│  └── Costs config               ├── security.json               │
│         │                       ├── docker.json                 │
│         │                       ├── web.json                    │
│         │                       └── costs.json                  │
│         │                              │                        │
└─────────┼──────────────────────────────┼────────────────────────┘
          │                              │
          ▼                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         FLASK API                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  routes.py              c3.py                                   │
│  /api/config            /api/c3/dashboard                       │
│  /api/vms               /api/c3/availability                    │
│  /api/services          /api/c3/performance                     │
│  /api/cloud_control/*   /api/c3/security                        │
│                         /api/c3/docker                          │
│                         /api/c3/web                             │
│                         /api/c3/costs                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Folder Structure

```
api/
├── app/
│   ├── api/
│   │   ├── routes.py       # Infrastructure (from architecture.json)
│   │   ├── c3.py           # C3 data (from 4.jsons/)
│   │   ├── admin.py        # Admin endpoints
│   │   ├── auth.py         # Authentication
│   │   └── web.py          # Web routes
│   ├── utils/
│   │   └── health.py       # Health check helpers
│   ├── config.py           # Load architecture.json
│   └── __init__.py
├── 1.ops/
│   └── build.sh            # Build script
├── run.py                  # Entry point
├── requirements.txt
├── Dockerfile
├── docker-compose.yml
└── README.md
```

---

## API Endpoints

### Infrastructure (routes.py)

| Endpoint | Description |
|----------|-------------|
| `GET /api/health` | Health check |
| `GET /api/config` | Full infrastructure config |
| `GET /api/vms` | List all VMs |
| `GET /api/vms/<vm_id>` | Get VM details |
| `GET /api/vms/<vm_id>/status` | Get VM health (ping, SSH) |
| `GET /api/services` | List all services |
| `GET /api/services/<svc_id>` | Get service details |
| `GET /api/cloud_control/monitor` | Monitor page data |
| `GET /api/cloud_control/costs_infra` | Infrastructure costs |
| `GET /api/cloud_control/costs_ai` | AI costs |

### C3 Data (c3.py)

| Endpoint | Source | Description |
|----------|--------|-------------|
| `GET /api/c3/dashboard` | dashboard.json | Aggregated alerts + status |
| `GET /api/c3/alerts` | dashboard.json | All alerts |
| `GET /api/c3/availability` | availability.json | VM ping, HTTP, SSL |
| `GET /api/c3/availability/status` | availability.json | Status summary |
| `GET /api/c3/availability/ssl` | availability.json | SSL cert expiry |
| `GET /api/c3/performance` | performance.json | CPU, RAM, disk |
| `GET /api/c3/performance/docker` | performance.json | Container stats |
| `GET /api/c3/docker` | docker.json | Full docker data |
| `GET /api/c3/security` | security.json | SSH attacks, ports |
| `GET /api/c3/security/failed-ssh` | security.json | Failed SSH by IP |
| `GET /api/c3/web` | web.json | NPM logs analysis |
| `GET /api/c3/web/threats` | web.json | Suspicious requests |
| `GET /api/c3/costs` | costs.json | All costs |
| `GET /api/c3/costs/infra` | costs.json | Cloud billing |
| `GET /api/c3/costs/ai` | costs.json | Claude token usage |
| `GET /api/c3/architecture` | architecture.json | Full topology |

---

## Setup

### Local Development

```bash
cd /home/diego/Documents/Git/back-System/cloud/a_solutions/api

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Set config path
export CLOUD_CONFIG_PATH=/home/diego/Documents/Git/back-System/cloud/0.spec/architecture.json

# Run
python run.py
```

### Docker

```bash
docker compose up -d
```

The `docker-compose.yml` mounts:
- `c3/in-house/4.jsons/` → `/app/c3-data/`
- `0.spec/architecture.json` → `/app/config/architecture.json`

---

## Quick Test

```bash
# Health
curl http://localhost:5000/api/health

# Infrastructure
curl http://localhost:5000/api/vms
curl http://localhost:5000/api/services

# C3 Data
curl http://localhost:5000/api/c3/dashboard
curl http://localhost:5000/api/c3/availability/status
curl http://localhost:5000/api/c3/security/failed-ssh
```

---

## Related

- **C3 Spec**: `../c3/in-house/SPEC.md`
- **Architecture**: `../../0.spec/architecture.json`

---

*Last Updated: 2025-12-15*
