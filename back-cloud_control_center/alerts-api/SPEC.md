# Alerts API - Central Alert & Log Audit Center

## Overview

REST API that receives alerts from collectors across VMs, stores them in SQLite, and forwards to ntfy for real-time notifications.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        ALERTS API                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Collectors (VMs)           Alerts API              Outputs      │
│  ─────────────────         ──────────              ───────       │
│                                                                  │
│  oci-flex/collector ──┐                                         │
│  gcp-arch/collector ──┼──► POST /api/alerts ──┬──► ntfy topics  │
│  oci-micro/collector ─┘         │              │                │
│                                 │              └──► SQLite DB   │
│                                 │                   (history)   │
│                                 ▼                               │
│                         GET /api/alerts ◄──── CloudFeed         │
│                         GET /api/stats                          │
│                         GET /api/services                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## API Endpoints

### Alerts

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/alerts` | Create new alert |
| GET | `/api/alerts` | Get alerts with filters |
| POST | `/api/alerts/{id}/ack` | Acknowledge alert |

### Stats & Status

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stats` | Get alert statistics |
| GET | `/api/services` | Get all services status |
| GET | `/api/vms` | Get all VMs status |
| POST | `/api/services/{name}/heartbeat` | Update service heartbeat |
| POST | `/api/vms/{name}/heartbeat` | Update VM heartbeat |
| GET | `/api/health` | Health check |

## Alert Schema

### POST /api/alerts

```json
{
  "vm": "oci-flex",
  "service": "ssh",
  "topic": "auth",
  "title": "SSH: 3 failed logins",
  "message": "Failed login attempts from 192.168.1.1",
  "priority": "high",
  "tags": "warning,lock",
  "log_path": "/var/log/auth.log",
  "log_cmd": "journalctl -u sshd --since '5 min ago'"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `vm` | Yes | VM identifier (oci-flex, gcp-arch, etc.) |
| `service` | Yes | Service name (ssh, docker, npm, etc.) |
| `topic` | Yes | ntfy topic (system, auth, sauron) |
| `title` | Yes | Alert title |
| `message` | No | Alert details |
| `priority` | No | critical, high, default, low, min |
| `tags` | No | Comma-separated ntfy tags |
| `log_path` | No | Path to full log file |
| `log_cmd` | No | Command to retrieve logs |

### GET /api/alerts

Query parameters:

| Param | Default | Description |
|-------|---------|-------------|
| `since` | 24h | Time filter (1h, 24h, 7d, or ISO timestamp) |
| `vm` | - | Filter by VM |
| `service` | - | Filter by service |
| `topic` | - | Filter by topic |
| `priority` | - | Filter by priority |
| `limit` | 100 | Max results |
| `offset` | 0 | Pagination offset |

Response:

```json
{
  "alerts": [
    {
      "id": 1,
      "timestamp": "2025-12-29T21:30:00",
      "vm": "oci-flex",
      "service": "ssh",
      "topic": "auth",
      "title": "SSH: 3 failed logins",
      "message": "Failed login attempts",
      "priority": "high",
      "tags": "warning,lock",
      "log_path": "/var/log/auth.log",
      "log_cmd": "journalctl -u sshd --since '5 min ago'",
      "acknowledged": 0,
      "ntfy_id": "abc123"
    }
  ],
  "total": 150,
  "limit": 100,
  "offset": 0
}
```

### GET /api/stats

Response:

```json
{
  "total": 150,
  "by_priority": {
    "critical": 2,
    "high": 15,
    "default": 100,
    "low": 33
  },
  "by_service": {
    "ssh": 20,
    "docker": 50,
    "npm": 30,
    "sauron": 10
  },
  "by_vm": {
    "oci-flex": 80,
    "gcp-arch": 70
  },
  "since": "2025-12-28T21:30:00"
}
```

## Collector Integration

Update collector to POST to API instead of directly to ntfy:

```bash
send_alert() {
    local topic="$1"
    local title="$2"
    local message="$3"
    local priority="${4:-default}"
    local tags="${5:-}"
    local service="${6:-system}"
    local log_cmd="${7:-}"

    curl -s -X POST "$API_URL/api/alerts" \
        -H "Content-Type: application/json" \
        -d "{
            \"vm\": \"$VM_NAME\",
            \"service\": \"$service\",
            \"topic\": \"$topic\",
            \"title\": \"$title\",
            \"message\": \"$message\",
            \"priority\": \"$priority\",
            \"tags\": \"$tags\",
            \"log_cmd\": \"$log_cmd\"
        }" > /dev/null 2>&1 || true
}
```

## Resource Limits

| Resource | Limit | Reason |
|----------|-------|--------|
| CPU | 10% (0.1 cores) | Minimal processing |
| RAM | 64 MB | SQLite + Flask |

## Deployment

### Docker Run

```bash
docker run -d \
  --name alerts-api \
  --restart unless-stopped \
  --cpus 0.1 \
  --memory 64m \
  -p 5050:5000 \
  -v alerts-data:/data \
  -e NTFY_URL=https://rss.diegonmarcos.com \
  --network npm_default \
  alerts-api:latest
```

### NPM Proxy Config

Add to NPM for `alerts.diegonmarcos.com`:

- Forward to: `alerts-api:5000`
- SSL: Let's Encrypt

## Files

```
alerts-api/
├── app/
│   └── main.py          # Flask API
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
└── SPEC.md              # This file
```
