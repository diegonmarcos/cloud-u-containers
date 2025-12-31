# Collector - Log Aggregator & Alert Forwarder

## Overview

Collector watches system logs (journald), Docker container logs, and Sauron alerts, then forwards them to the Alerts API (which stores and forwards to ntfy).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    collector container                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  SOURCES                              DESTINATIONS               │
│  ───────                              ────────────               │
│                                                                  │
│  journald ──┬── SSH events ────────►  Alerts API ──► ntfy/auth  │
│             ├── Docker events ─────►  Alerts API ──► ntfy/system│
│             └── Critical logs ─────►  Alerts API ──► ntfy/system│
│                                                                  │
│  Sauron ────── Malware alerts ─────►  Alerts API ──► ntfy/sauron│
│                                                                  │
│  Heartbeat ──────────────────────────► Alerts API (VM status)   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
           https://alerts.diegonmarcos.com (API)
                              │
                              ▼
           https://rss.diegonmarcos.com (ntfy fallback)
```

## Alert Payload

Each alert sent to API includes:

```json
{
  "vm": "oci-flex",
  "service": "ssh",
  "topic": "auth",
  "title": "SSH: 3 failed logins",
  "message": "[oci-flex] 3 failed SSH login attempts",
  "priority": "high",
  "tags": "warning,lock",
  "log_cmd": "journalctl -u sshd --since '30s ago' --no-pager"
}
```

The `log_cmd` field allows CloudFeed users to copy the command and run it on the VM to get full logs.

## What It Monitors

### SSH (→ auth topic)

| Event | Priority | Tags | log_cmd |
|-------|----------|------|---------|
| Failed login attempts | high | warning, lock | `journalctl -u sshd --since '30s ago'` |
| Successful logins | default | key, unlock | `journalctl -u sshd --since '30s ago' \| grep Accepted` |

### Docker (→ system topic)

| Event | Priority | Tags | log_cmd |
|-------|----------|------|---------|
| Container crash/kill/OOM | high | whale, warning | `journalctl -u docker --since '30s ago' \| grep -E 'died\|killed\|OOM'` |

### System (→ system topic)

| Event | Priority | Tags | log_cmd |
|-------|----------|------|---------|
| Critical/Emergency logs (priority 0-2) | urgent | rotating_light | `journalctl -p 0..2 --since '30s ago'` |

### Sauron (→ sauron topic)

| Event | Priority | Tags | log_cmd |
|-------|----------|------|---------|
| Malware detection | urgent | biohazard, skull | `docker logs sauron --since '30s'` |

## Resource Limits

| Resource | Limit | Reason |
|----------|-------|--------|
| CPU | 5% (0.05 cores) | Minimal processing |
| RAM | 32 MB | Just reads and forwards |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_URL` | `https://alerts.diegonmarcos.com` | Alerts API URL |
| `NTFY_URL` | `https://rss.diegonmarcos.com` | ntfy fallback URL |
| `VM_NAME` | `unknown` | VM identifier in alerts |
| `CHECK_INTERVAL` | `30` | Seconds between checks |

### Docker Run

```bash
docker run -d \
  --name collector \
  --restart unless-stopped \
  --network host \
  --cpus 0.05 \
  --memory 32m \
  -v /var/log/journal:/var/log/journal:ro \
  -v /run/log/journal:/run/log/journal:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e API_URL=https://alerts.diegonmarcos.com \
  -e NTFY_URL=https://rss.diegonmarcos.com \
  -e VM_NAME=oci-flex \
  -e CHECK_INTERVAL=30 \
  collector:latest
```

### Required Mounts

| Mount | Purpose |
|-------|---------|
| `/var/log/journal` | Read journald logs |
| `/run/log/journal` | Read journald logs (volatile) |
| `/etc/machine-id` | Required by journalctl |
| `/var/run/docker.sock` | Read Docker container logs |

### Network

Must use `--network host` to reach external API/ntfy servers.

## Fallback Behavior

1. Collector tries to POST alert to Alerts API
2. If API fails or returns error, falls back to direct ntfy POST
3. This ensures alerts are never lost even if API is down

## Heartbeat

Every check interval, collector sends a heartbeat to:
```
POST /api/vms/{VM_NAME}/heartbeat
```

This allows the CloudFeed dashboard to show VM online/offline status.

## Files

```
collector/
├── Dockerfile         # Debian slim + curl + journalctl
├── collector.sh       # Main script
└── SPEC.md            # This file
```
