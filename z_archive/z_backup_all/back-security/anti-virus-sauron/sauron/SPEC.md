# Sauron - YARA Malware Scanner

## Overview

Sauron is a Rust-based file system scanner that uses YARA rules to detect malware, webshells, and suspicious patterns.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      sauron container                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐      ┌──────────────────────────┐         │
│  │ YARA Engine  │ ──── │ Rules (.yar files)       │         │
│  │ (Rust binary)│      │ - webshells.yar          │         │
│  └──────┬───────┘      │ - cryptominers.yar       │         │
│         │              │ - suspicious.yar         │         │
│         │              └──────────────────────────┘         │
│         │ scans                                              │
│         ▼                                                    │
│  ┌──────────────────────────────────────────────┐           │
│  │           Watch Paths (read-only)            │           │
│  │  /watch/etc ◄──── /etc (system configs)      │           │
│  │  /watch/docker-volumes ◄── Docker data       │           │
│  └──────────────────────────────────────────────┘           │
│         │                                                    │
│         ▼                                                    │
│  ┌──────────────┐                                           │
│  │ Docker logs  │ ─── JSON alerts                           │
│  └──────────────┘                                           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Scan Modes

### Incremental (Default)

```
Startup:    Full scan of all files (baseline)
Hour 1:     Only files modified since startup
Hour 2:     Only files modified since Hour 1
...
```

Uses `find -newer` to detect modified files.

### Full Scan

Every scan checks all files regardless of modification time.

## Resource Limits

| Resource | Limit | Reason |
|----------|-------|--------|
| CPU | 25% (0.25 cores) | Safe for 1 vCPU free-tier VMs |
| RAM | 256 MB | Handles large scans without OOM |
| Workers | 1 | Single-threaded to limit CPU |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RULES_DIR` | `/etc/sauron/yara-rules` | Path to YARA rules |
| `WATCH_DIR` | `/watch` | Root directory to scan |
| `SCAN_INTERVAL` | `3600` | Seconds between scans |
| `WORKERS` | `1` | Number of scan threads |

### Docker Compose

```yaml
sauron:
  container_name: sauron
  build:
    context: .
    dockerfile: Dockerfile.sauron
  cpus: "0.25"
  mem_limit: 256m
  volumes:
    - /etc:/watch/etc:ro
    - /var/lib/docker/volumes:/watch/docker-volumes:ro
    - ./yara-rules:/etc/sauron/yara-rules:ro
    - ./entrypoint.sh:/entrypoint.sh:ro
  environment:
    - RULES_DIR=/etc/sauron/yara-rules/custom
    - WATCH_DIR=/watch
    - SCAN_INTERVAL=3600
    - WORKERS=1
```

## YARA Rules

### webshells.yar

Detects PHP/JSP backdoors and web shells:
- `PHP_WebShell_Generic` - eval($_POST), system($_GET), etc.
- `PHP_Backdoor_C99` - C99/R57 shell variants
- `JSP_WebShell` - Java web shells

### cryptominers.yar

Detects cryptocurrency mining scripts:
- `Cryptominer_Generic` - XMRig, stratum+tcp, etc.
- `Cryptominer_JS` - Browser-based miners (Coinhive patterns)

### suspicious.yar

Detects suspicious patterns:
- `Suspicious_Reverse_Shell` - Bash/Python/Perl reverse shells
- `Suspicious_Credential_Access` - /etc/shadow, .ssh/id_rsa access
- `Suspicious_Encoded_Payload` - Base64 in scripts
- `Suspicious_Docker_Escape` - Container escape attempts

## Output Format

JSON output to Docker logs:

```json
{
  "detections": [
    {
      "path": "/watch/home/user/malware.php",
      "size": 1234,
      "scanned_at": 1767034832,
      "time": 0.000103,
      "error": null,
      "detected": true,
      "tags": ["PHP_WebShell_Generic"]
    }
  ]
}
```

## Logs

```bash
# View sauron logs
docker logs sauron

# Follow logs
docker logs -f sauron

# Check for alerts
docker logs sauron 2>&1 | grep ALERT
```

## Files

```
sauron/
├── Dockerfile.sauron      # Multi-stage build (Rust → slim)
├── docker-compose.yml     # Full stack config
├── entrypoint.sh          # Scan loop script
├── yara-rules/
│   └── custom/
│       ├── webshells.yar
│       ├── cryptominers.yar
│       └── suspicious.yar
└── SPEC.md                # This file
```
