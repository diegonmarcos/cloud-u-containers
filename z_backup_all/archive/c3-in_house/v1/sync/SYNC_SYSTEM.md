# Sync System: Logs + Objects

> **Version**: 2.0.0 | **Updated**: 2025-12-23

---

## Overview

Two-channel sync system for security data consolidation across all VMs:

| Channel | Data Type | Tool | Protocol | Storage |
|---------|-----------|------|----------|---------|
| **Logs** | Alerts, auth, firewall, docker | syslog-ng | TCP :5514 | SQLite |
| **Objects** | Binaries, samples, files | rclone | SFTP/rsync | Filesystem |

### VMs Covered

| VM ID | IP | Services | Log Types |
|-------|-----|----------|-----------|
| oci-f-micro_1 | 130.110.251.193 | Mailu Mail | auth, docker, mail |
| oci-f-micro_2 | 129.151.228.66 | Matomo Analytics | auth, docker, web |
| gcp-f-micro_1 | 34.55.55.234 | NPM, Authelia | auth, firewall, proxy |
| oci-p-flex_1 | 84.235.234.87 | Photos, Sync, **Central DB** | auth, docker, files |

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CENTRAL SIEM ARCHITECTURE                            │
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐           │
│  │  oci-f-micro_1   │  │  oci-f-micro_2   │  │  gcp-f-micro_1   │           │
│  │  130.110.251.193 │  │  129.151.228.66  │  │  34.55.55.234    │           │
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
│                          TCP :5514 (streaming)                               │
│                                 │                                            │
│                                 ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │            CENTRAL SERVER (oci-p-flex_1) 84.235.234.87                │   │
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
│  │   │  │   - vms             │        │    ├── by_category/     │  │   │   │
│  │   │  │   - alerts          │        │    └── daily/           │  │   │   │
│  │   │  │   - auth_events     │        └─────────────────────────┘  │   │   │
│  │   │  │   - firewall_events │                                     │   │   │
│  │   │  │   - docker_events   │        ┌─────────────────────────┐  │   │   │
│  │   │  │   - system_events   │        │    Sample Storage       │  │   │   │
│  │   │  │   - heartbeats      │        │    /var/siem/samples/   │  │   │   │
│  │   │  └─────────────────────┘        │    └── by_vm/           │  │   │   │
│  │   │                                 └─────────────────────────┘  │   │   │
│  │   └──────────────────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation Files

| File | Purpose |
|------|---------|
| `central_db/schema.sql` | SQLite database schema |
| `central_db/agent/siem_agent.py` | Python log collector |
| `central_db/configs/vm-syslog-ng.conf` | VM sender config |
| `central_db/configs/central-syslog-ng.conf` | Central receiver config |
| `central_db/README.md` | Deployment guide |

---

## Channel 1: Logs (syslog-ng → TCP)

### Why syslog-ng?

| Feature | Benefit |
|---------|---------|
| Native SQLite | Direct DB writes, no middleware |
| JSON parsing | Structured log queries |
| TCP reliable | No lost alerts |
| Low RAM | ~20 MB |

### VM Configuration (Sender)

```conf
# /etc/syslog-ng/syslog-ng.conf

@version: 4.0

# Sources
source s_sauron {
    file("/var/log/sauron/alerts.jsonl"
         follow-freq(1)
         flags(no-parse));
};

source s_yara {
    file("/var/log/sauron/yara.jsonl"
         follow-freq(1)
         flags(no-parse));
};

# Add hostname to each message
rewrite r_add_host {
    set("${HOST}" value(".sauron.host"));
};

# Destination: Central server
destination d_central {
    tcp("central.internal" port(5514)
        template("${MSG}\n"));
};

# Destination: Local SQLite backup
destination d_local_sqlite {
    sql(
        type(sqlite3)
        database("/var/log/sauron/local.db")
        table("alerts")
        columns("timestamp", "host", "raw")
        values("${ISODATE}", "${HOST}", "${MSG}")
    );
};

# Log paths
log {
    source(s_sauron);
    source(s_yara);
    rewrite(r_add_host);
    destination(d_central);
    destination(d_local_sqlite);
};
```

### Central Configuration (Receiver)

```conf
# /etc/syslog-ng/syslog-ng.conf

@version: 4.0

# Receive from VMs
source s_network {
    tcp(port(5514)
        flags(no-parse));
};

# Parse JSON
parser p_json {
    json-parser(prefix(".json."));
};

# Store in SQLite
destination d_sqlite {
    sql(
        type(sqlite3)
        database("/var/siem/alerts.db")
        table("alerts")
        columns("timestamp", "host", "severity", "rule", "file", "hash", "raw")
        values(
            "${.json.timestamp}",
            "${.json.host}",
            "${.json.severity}",
            "${.json.rule}",
            "${.json.file}",
            "${.json.hash}",
            "${MSG}"
        )
        indexes("timestamp", "host", "severity")
    );
};

# Also keep raw JSONL for backup
destination d_jsonl {
    file("/var/siem/alerts.jsonl"
         template("${MSG}\n"));
};

log {
    source(s_network);
    parser(p_json);
    destination(d_sqlite);
    destination(d_jsonl);
};
```

---

## Channel 2: Objects (rclone → SFTP)

### Why rclone?

| Feature | Benefit |
|---------|---------|
| Batch sync | Efficient for large files |
| Deduplication | Skip already-synced samples |
| Bandwidth limit | Don't saturate network |
| Encryption | Optional at-rest encryption |

### What gets synced?

| Object Type | Source Path | Description |
|-------------|-------------|-------------|
| Quarantined files | `/var/quarantine/` | YARA-detected malware |
| Memory dumps | `/var/sauron/dumps/` | Process memory captures |
| Suspicious binaries | `/var/sauron/samples/` | Files flagged for analysis |

### VM Configuration (Sender)

```bash
# /etc/rclone/rclone.conf
[central-siem]
type = sftp
host = central.internal
user = siem-sync
key_file = /etc/sauron/ssh/id_rsa
```

```bash
# /etc/sauron/sync-objects.sh
#!/bin/bash

HOSTNAME=$(hostname)
REMOTE="central-siem:/var/siem/samples/${HOSTNAME}/"

# Sync quarantine (delete after successful sync)
rclone move /var/quarantine/ "${REMOTE}quarantine/" \
    --bwlimit 1M \
    --log-file /var/log/sauron/rclone.log

# Sync memory dumps
rclone sync /var/sauron/dumps/ "${REMOTE}dumps/" \
    --bwlimit 1M \
    --max-age 7d

# Sync suspicious samples
rclone sync /var/sauron/samples/ "${REMOTE}samples/" \
    --bwlimit 1M
```

### Cron Schedule

```bash
# /etc/cron.d/sauron-sync
# Sync objects every 15 minutes
*/15 * * * * root /etc/sauron/sync-objects.sh

# Alternative: systemd timer
# See: sync-objects.timer
```

### systemd Timer (Alternative)

```ini
# /etc/systemd/system/sync-objects.service
[Unit]
Description=Sync quarantine objects to central

[Service]
Type=oneshot
ExecStart=/etc/sauron/sync-objects.sh

# /etc/systemd/system/sync-objects.timer
[Unit]
Description=Run object sync every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
```

### Central Storage Layout

```
/var/siem/
├── alerts.db              # SQLite SIEM database
├── alerts.jsonl           # Raw JSON backup
└── samples/               # Synced objects
    ├── oci-micro1/
    │   ├── quarantine/
    │   ├── dumps/
    │   └── samples/
    ├── oci-micro2/
    │   └── ...
    ├── oci-flex1/
    │   └── ...
    └── gcp-micro1/
        └── ...
```

---

## Comparison: Logs vs Objects

| Aspect | Logs (syslog-ng) | Objects (rclone) |
|--------|------------------|------------------|
| Data type | JSON text | Binary files |
| Latency | Real-time (~1s) | Batch (15min) |
| Transport | TCP streaming | SFTP batch |
| Size | Small (KB/event) | Large (MB/file) |
| Storage | SQLite | Filesystem |
| Retention | Indexed, queryable | Archive |

---

## Security

### Log Channel (syslog-ng)

```conf
# Add TLS
destination d_central {
    tcp("central.internal" port(5514)
        tls(
            ca-file("/etc/sauron/certs/ca.pem")
            cert-file("/etc/sauron/certs/client.pem")
            key-file("/etc/sauron/certs/client.key")
        )
    );
};
```

### Object Channel (rclone)

```bash
# SSH key auth (already configured)
# Optional: encrypt samples at rest
rclone sync /var/quarantine/ central-siem:/samples/ --crypt-remote
```

---

## RAM Summary

| Component | VM (each) | Central |
|-----------|-----------|---------|
| syslog-ng | 20 MB | 25 MB |
| rclone (during sync) | 30 MB | - |
| SQLite | 5 MB | 10 MB |
| **Total** | **~55 MB** | **~35 MB** |

---

## Query Examples

```bash
# All critical alerts (last 24h)
sqlite3 /var/siem/alerts.db "
    SELECT timestamp, host, rule, file
    FROM alerts
    WHERE severity = 'critical'
    AND timestamp > datetime('now', '-1 day')
    ORDER BY timestamp DESC;
"

# YARA matches by rule
sqlite3 /var/siem/alerts.db "
    SELECT rule, COUNT(*) as hits
    FROM alerts
    WHERE rule IS NOT NULL
    GROUP BY rule
    ORDER BY hits DESC;
"

# Files changed on specific host
sqlite3 /var/siem/alerts.db "
    SELECT timestamp, file, hash
    FROM alerts
    WHERE host = 'oci-micro1'
    ORDER BY timestamp DESC
    LIMIT 50;
"

# Live tail with jq
tail -f /var/siem/alerts.jsonl | jq 'select(.severity == "critical")'
```

---

## References

- Deployment plan: `./PLAN_DEPLOY.md`
- syslog-ng docs: https://syslog-ng.github.io/
- rclone docs: https://rclone.org/docs/
