# Central Security Database (SIEM)

> **Version**: 1.0.0 | **Updated**: 2025-12-23

---

## Overview

Centralized security logging system that consolidates logs from all VMs into a single SQLite database.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CENTRAL SIEM ARCHITECTURE                            │
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐           │
│  │  oci-f-micro_1   │  │  oci-f-micro_2   │  │  gcp-f-micro_1   │           │
│  │  (Mail Server)   │  │  (Analytics)     │  │  (Proxy/Auth)    │           │
│  │                  │  │                  │  │                  │           │
│  │  ┌────────────┐  │  │  ┌────────────┐  │  │  ┌────────────┐  │           │
│  │  │ syslog-ng  │  │  │  │ syslog-ng  │  │  │  │ syslog-ng  │  │           │
│  │  │  (sender)  │  │  │  │  (sender)  │  │  │  │  (sender)  │  │           │
│  │  └─────┬──────┘  │  │  └─────┬──────┘  │  │  └─────┬──────┘  │           │
│  └────────┼─────────┘  └────────┼─────────┘  └────────┼─────────┘           │
│           │                     │                     │                      │
│           └─────────────────────┼─────────────────────┘                      │
│                                 │                                            │
│                          TCP :5514                                           │
│                                 │                                            │
│                                 ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    CENTRAL SERVER (oci-p-flex_1)                      │   │
│  │                                                                       │   │
│  │   ┌──────────────────────────────────────────────────────────────┐   │   │
│  │   │                     syslog-ng (receiver)                      │   │   │
│  │   │                           │                                   │   │   │
│  │   │    ┌──────────────────────┴───────────────────────┐          │   │   │
│  │   │    │                                              │          │   │   │
│  │   │    ▼                                              ▼          │   │   │
│  │   │  ┌─────────────────────┐        ┌─────────────────────────┐  │   │   │
│  │   │  │   SQLite Database   │        │    JSONL File Backups   │  │   │   │
│  │   │  │   /var/siem/        │        │    /var/siem/logs/      │  │   │   │
│  │   │  │   security.db       │        │    ├── all_events.jsonl │  │   │   │
│  │   │  │                     │        │    ├── critical.jsonl   │  │   │   │
│  │   │  │   Tables:           │        │    ├── by_vm/           │  │   │   │
│  │   │  │   - alerts          │        │    ├── by_category/     │  │   │   │
│  │   │  │   - auth_events     │        │    └── daily/           │  │   │   │
│  │   │  │   - firewall_events │        └─────────────────────────┘  │   │   │
│  │   │  │   - docker_events   │                                     │   │   │
│  │   │  │   - system_events   │                                     │   │   │
│  │   │  │   - heartbeats      │                                     │   │   │
│  │   │  └─────────────────────┘                                     │   │   │
│  │   └──────────────────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **Schema** | `schema.sql` | SQLite database schema |
| **Agent** | `agent/siem_agent.py` | Python collector (alternative to syslog-ng) |
| **VM Config** | `configs/vm-syslog-ng.conf` | syslog-ng sender config |
| **Central Config** | `configs/central-syslog-ng.conf` | syslog-ng receiver config |

---

## Database Schema

### Tables

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `vms` | VM registry | vm_id, public_ip, status |
| `alerts` | Security alerts | severity, category, rule, file_path |
| `auth_events` | SSH/sudo events | event_type, username, source_ip, success |
| `firewall_events` | UFW blocks/allows | action, src_ip, dst_port |
| `docker_events` | Container lifecycle | event_type, container_name, image |
| `system_events` | Boot, services, kernel | event_type, service_name, status |
| `heartbeats` | Agent health checks | uptime, memory, disk, load_avg |

### Views

| View | Purpose |
|------|---------|
| `v_critical_alerts` | Critical alerts last 24h |
| `v_failed_ssh` | Failed SSH attempts last 24h |
| `v_blocked_ips` | Blocked IPs with counts |
| `v_vm_health` | VM health status from heartbeats |
| `v_alert_summary` | Alert counts by VM/severity |

---

## Deployment

### 1. Central Server Setup (oci-p-flex_1)

```bash
# SSH to central server
ssh -i ~/.ssh/id_rsa ubuntu@84.235.234.87

# Create directories
sudo mkdir -p /var/siem/{logs/{by_vm,by_category,daily},samples}
sudo chown -R syslog:adm /var/siem

# Install syslog-ng
sudo apt install syslog-ng syslog-ng-mod-sql

# Initialize database
sudo sqlite3 /var/siem/security.db < schema.sql

# Copy config
sudo cp configs/central-syslog-ng.conf /etc/syslog-ng/syslog-ng.conf

# Start
sudo systemctl restart syslog-ng
sudo systemctl enable syslog-ng

# Verify
sudo ss -tlnp | grep 5514
```

### 2. VM Agent Setup (each VM)

```bash
# Set VM identifier
export SIEM_VM_ID="oci-f-micro_1"  # Change for each VM
export SIEM_CENTRAL_HOST="84.235.234.87"

# Option A: syslog-ng
sudo apt install syslog-ng
sudo cp configs/vm-syslog-ng.conf /etc/syslog-ng/conf.d/siem.conf
echo "SIEM_VM_ID=$SIEM_VM_ID" | sudo tee -a /etc/default/syslog-ng
echo "SIEM_CENTRAL_HOST=$SIEM_CENTRAL_HOST" | sudo tee -a /etc/default/syslog-ng
sudo systemctl restart syslog-ng

# Option B: Python agent
sudo apt install python3
sudo cp agent/siem_agent.py /usr/local/bin/
sudo chmod +x /usr/local/bin/siem_agent.py
# Create systemd service (see below)
```

### 3. Systemd Service for Python Agent

```ini
# /etc/systemd/system/siem-agent.service
[Unit]
Description=SIEM Agent
After=network.target

[Service]
Type=simple
Environment="SIEM_VM_ID=oci-f-micro_1"
Environment="SIEM_CENTRAL_HOST=84.235.234.87"
Environment="SIEM_CENTRAL_PORT=5514"
ExecStart=/usr/bin/python3 /usr/local/bin/siem_agent.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

---

## Firewall Rules

### Central Server (oci-p-flex_1)

```bash
# Allow syslog from VMs
sudo ufw allow from 130.110.251.193 to any port 5514  # oci-f-micro_1
sudo ufw allow from 129.151.228.66 to any port 5514   # oci-f-micro_2
sudo ufw allow from 34.55.55.234 to any port 5514     # gcp-f-micro_1
```

### VMs (outbound)

```bash
# Allow outbound to central
sudo ufw allow out to 84.235.234.87 port 5514
```

---

## Queries

### Critical Alerts (last 24h)

```sql
SELECT timestamp, vm_id, severity, rule, message
FROM alerts
WHERE severity IN ('critical', 'alert', 'emergency')
  AND timestamp > datetime('now', '-1 day')
ORDER BY timestamp DESC;
```

### Failed SSH by IP

```sql
SELECT source_ip, COUNT(*) as attempts, MAX(timestamp) as last_seen
FROM auth_events
WHERE event_type = 'ssh_fail' AND success = 0
GROUP BY source_ip
ORDER BY attempts DESC
LIMIT 20;
```

### Blocked IPs (Top 20)

```sql
SELECT src_ip, COUNT(*) as blocks,
       GROUP_CONCAT(DISTINCT dst_port) as ports
FROM firewall_events
WHERE action = 'BLOCK'
GROUP BY src_ip
ORDER BY blocks DESC
LIMIT 20;
```

### VM Health Check

```sql
SELECT * FROM v_vm_health;
```

### Alert Summary by VM

```sql
SELECT vm_id, severity, COUNT(*) as count
FROM alerts
WHERE timestamp > datetime('now', '-7 day')
GROUP BY vm_id, severity
ORDER BY vm_id, count DESC;
```

---

## RAM & Storage Estimates

| Component | RAM Usage | Storage/Day |
|-----------|-----------|-------------|
| syslog-ng (VM) | ~20 MB | N/A |
| syslog-ng (Central) | ~30 MB | N/A |
| SQLite DB | ~10 MB | ~5-20 MB |
| JSONL backups | N/A | ~10-50 MB |
| **Total** | **~60 MB** | **~50 MB/day** |

---

## Retention Policy

| Data Type | Retention | Cleanup |
|-----------|-----------|---------|
| Heartbeats | 7 days | Automatic (trigger) |
| Firewall events | 30 days | Automatic (trigger) |
| Auth events | 90 days | Manual/cron |
| Alerts | 1 year | Manual |
| JSONL daily | 30 days | Cron job |

### Cleanup Cron

```bash
# /etc/cron.daily/siem-cleanup
#!/bin/bash
# Delete old JSONL files
find /var/siem/logs/daily -name "*.jsonl" -mtime +30 -delete

# Vacuum database
sqlite3 /var/siem/security.db "VACUUM;"
```

---

## Monitoring

### Check Central is Receiving

```bash
# Watch incoming connections
sudo ss -tn src :5514

# Tail live logs
tail -f /var/siem/logs/all_events.jsonl | jq

# Check database size
ls -lh /var/siem/security.db

# Count events today
sqlite3 /var/siem/security.db \
  "SELECT COUNT(*) FROM alerts WHERE timestamp > datetime('now', '-1 day');"
```

### Check VM is Sending

```bash
# Check syslog-ng status
sudo systemctl status syslog-ng

# Check TCP connection
nc -zv 84.235.234.87 5514

# Check local fallback (if any)
cat /var/log/siem_fallback.jsonl
```

---

## Next Steps

1. [ ] Deploy central receiver on oci-p-flex_1
2. [ ] Deploy agents on each VM
3. [ ] Configure TLS certificates for production
4. [ ] Set up alerting (email/webhook for critical events)
5. [ ] Create Grafana dashboard
6. [ ] Integrate with object sync (rclone for samples)
