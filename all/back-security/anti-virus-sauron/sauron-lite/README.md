# Sauron-Lite

Hybrid file integrity monitor + YARA scanner for resource-constrained VMs.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      VM (1GB RAM)                           │
│                                                             │
│  ┌────────────────────┐       ┌────────────────────┐       │
│  │ WATCHER (always)   │       │ SCANNER (cron)     │       │
│  │ inotifywait        │       │ YARA rules         │       │
│  │ ~2 MB RAM          │       │ every 5 min        │       │
│  │                    │       │ ~20 MB (burst)     │       │
│  │ Monitors:          │       │                    │       │
│  │ - /etc             │──────▶│ Scans ONLY files   │       │
│  │ - /home            │ queue │ that changed       │       │
│  │                    │       │                    │       │
│  └────────────────────┘       └─────────┬──────────┘       │
│                                         │                   │
│                                         ▼                   │
│                                  alerts.jsonl               │
│                                         │                   │
│  ┌──────────────────────────────────────┴─────────────────┐│
│  │ FORWARDER (netcat) ──────────────────▶ Central Server  ││
│  └────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Watcher** (always running, ~2MB)
   - Uses `inotifywait` to detect file changes
   - Queues suspicious files (`.sh`, `.py`, `.php`, etc.) for scanning

2. **Scanner** (cron every 5 min, ~20MB burst)
   - Runs YARA rules against queued files only
   - Generates alerts for malware matches

3. **Forwarder** (always running, ~1MB)
   - Sends alerts to central collector

## vs Original Sauron

| Metric | Original | Sauron-Lite |
|--------|----------|-------------|
| Image size | 150 MB | **15 MB** |
| RAM (idle) | 50-150 MB | **2-5 MB** |
| RAM (scan) | 150+ MB | **20-30 MB** |
| CPU (idle) | 5-10% | **<1%** |
| YARA scanning | Real-time (everything) | **Periodic (changed files only)** |
| Protection | ✅ | ✅ |

## YARA Rules Included

```
yara-rules/custom/
├── webshells.yar     # PHP/JSP/ASP webshells
├── cryptominers.yar  # Cryptocurrency miners
└── suspicious.yar    # Reverse shells, credential theft
```

## Resource Limits (Enforced)

| Container | Memory | CPU |
|-----------|--------|-----|
| sauron | 64 MB max | 20% |
| forwarder | 16 MB max | 5% |
| **Total** | **80 MB max** | **25%** |

## Deploy

```bash
cd /home/diego/Documents/Git/back-System/cloud/a_solutions/back-security/anti-virus/sauron-lite

# Deploy to all VMs
./deploy.sh deploy

# Deploy to specific VM
./deploy.sh deploy oci-micro-1

# Check status
./deploy.sh status
```

## Alert Format

```json
{
  "timestamp": "2024-12-29T12:00:00Z",
  "vm": "oci-micro-1",
  "severity": "high",
  "rule": "webshell_php_generic",
  "path": "/watch/home/user/backdoor.php"
}
```

## Files

```
sauron-lite/
├── watcher.sh        # File change detector (inotifywait)
├── scanner.sh        # YARA scanner (cron-based)
├── entrypoint.sh     # Container startup
├── Dockerfile        # Alpine + inotify + yara (~15MB)
├── docker-compose.yml# With memory limits
├── deploy.sh         # Deployment script
└── yara-rules/       # Malware signatures
```
