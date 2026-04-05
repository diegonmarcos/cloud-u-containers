# Palantir Monitor (Lite)

> "The Palantíri were made by the Elves of Valinor... those who looked into them could perceive events and places far away in space and time."

## Overview

Lightweight cloud infrastructure monitoring container (~30MB RAM) that generates comprehensive health reports and sends them via email.

## Lite vs Full

| Feature | Lite (current) | Full |
|---------|----------------|------|
| Image Size | ~15MB | ~1.2GB |
| RAM Usage | ~30MB | ~400MB |
| OCI CLI | No (uses SSH) | Yes |
| GCloud CLI | No (uses SSH) | Yes |
| Cloud APIs | Via SSH to VMs | Direct CLI |

## Features

| Check | Description |
|-------|-------------|
| **External Connectivity** | HTTP/port/DNS checks from outside |
| **Cloud Status** | VM health via SSH (uptime, load, memory, disk) |
| **Docker Summary** | Container counts across all VMs |
| **Port Analysis** | Expected vs actual open ports |
| **IP Inventory** | DNS records vs expected IPs |
| **Security Audit** | SSL certs, headers, exposed services |
| **Malware Reports** | Sauron YARA alerts from all VMs |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  palantir-monitor (lite)                     │
│                     Alpine ~15MB                             │
├─────────────────────────────────────────────────────────────┤
│  Tools: bash, curl, jq, nc, dig, openssl, ssh, swaks        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ check-   │  │ check-   │  │ check-   │  │ check-   │    │
│  │ external │  │ cloud    │  │ docker   │  │ ports    │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       │             │             │             │           │
│       │    ┌────────┴─────────────┴─────────────┘           │
│       │    │  SSH to VMs (no heavy CLIs)                    │
│       │    │                                                │
│       ▼    ▼                                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   run-checks.sh                      │   │
│  │               (orchestrator)                         │   │
│  └───────────────────────┬─────────────────────────────┘   │
│                          │                                  │
│         ┌────────────────┼────────────────┐                │
│         ▼                ▼                ▼                │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐           │
│  │ MD Report  │  │ HTML       │  │ JSON       │           │
│  │ (stored)   │  │ Report     │  │ Report     │           │
│  └────┬───────┘  └────┬───────┘  └────┬───────┘           │
│       │               │               │                    │
│       └───────────────┴───────────────┘                    │
│                       │                                    │
│                       ▼                                    │
│              ┌────────────────┐                            │
│              │ Email via      │                            │
│              │ Mailu SMTPS    │                            │
│              │ (HTML + 3 att.)│                            │
│              └────────────────┘                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
         │
         │ SSH
         ▼
    ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
    │oci-m-1 │  │oci-m-2 │  │gcp-m-1 │  │oci-f-1 │
    │ Mail   │  │ Matomo │  │ Proxy  │  │ Photos │
    └─────────┘  └─────────┘  └─────────┘  └─────────┘
```

## Resource Usage

| Resource | Limit | Actual |
|----------|-------|--------|
| Image | ~15MB | Alpine + tools |
| RAM | 64MB cap | ~30MB typical |
| CPU | 0.25 cores | Burst during checks |
| Storage | ~50MB/year | MD reports |

## Configuration

### Required Mount

```yaml
volumes:
  - ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro  # SSH key for VM access
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SMTP_USER` | no-reply@diegonmarcos.com | SMTP auth username |
| `SMTP_PASS` | (required) | SMTP auth password |
| `SMTP_PROXY_URL` | http://smtp.diegonmarcos.com:8080/ | Fallback email endpoint |
| `SMTP_PROXY_KEY` | <redacted-api-key> | Fallback API key |
| `OCI_MICRO_1` | 130.110.251.193 | Mail server IP |
| `OCI_MICRO_2` | 129.151.228.66 | Analytics IP |
| `GCP_MICRO_1` | 35.226.147.64 | Proxy IP |
| `OCI_FLEX_1` | 84.235.234.87 | Photos IP |

## Usage

### Manual Run
```bash
# With email (requires SMTP password)
docker-compose run --rm -e SMTP_PASS=your_password palantir-monitor

# Without email (console output only)
docker-compose run --rm palantir-monitor
```

### Scheduled (7 AM UTC daily)
```bash
docker-compose up -d palantir-cron
```

### View Reports
```bash
docker volume ls | grep palantir
docker run --rm -v palantir-monitor_palantir-reports:/reports alpine ls -la /reports
```

## Report Sections

1. **External Connectivity** - VM SSH, web services, mail ports, DNS
2. **Cloud Infrastructure** - Uptime, load, memory, disk per VM
3. **Docker Summary** - Running/stopped/unhealthy counts
4. **Port Analysis** - Expected vs actual, risky port scan
5. **IP Inventory** - DNS resolution check
6. **Security Checks** - SSL expiry, headers
7. **Malware Reports** - Sauron alerts from all VMs

### Report Formats

Each run generates three report files:
- **Markdown** (`health-report-YYYYMMDD-HHMMSS.md`) - Human-readable text format
- **HTML** (`health-report-YYYYMMDD-HHMMSS.html`) - Styled web format with CSS
- **JSON** (`health-report-YYYYMMDD-HHMMSS.json`) - Machine-readable data with metadata

## Files

```
palantir-monitor/
├── Dockerfile              # Alpine + lightweight tools
├── docker-compose.yml      # 64MB RAM limit
├── SPEC.md                 # This file
├── config/
│   └── endpoints.conf      # IPs, domains
└── scripts/
    ├── run-checks.sh       # Orchestrator
    ├── generate-html.sh    # MD to HTML converter
    ├── check-external.sh   # HTTP/port/DNS
    ├── check-cloud.sh      # VM health via SSH
    ├── check-docker.sh     # Container summary
    ├── check-ports.sh      # Port scanning
    ├── check-ips.sh        # IP inventory
    ├── check-security.sh   # SSL/headers
    └── check-sauron.sh     # Malware reports
```

## Email Output

- **From:** no-reply@diegonmarcos.com
- **To:** me@diegonmarcos.com
- **Subject:** `[OK]`, `[WARN]`, or `[ALERT]` based on findings
- **Body:** Styled HTML report with:
  - Professional CSS styling (blue theme)
  - Color-coded status indicators (✅ OK, ⚠️ WARN, ❌ FAIL)
  - Responsive tables with hover effects
  - ASCII topology diagrams
- **Attachments:**
  - `health-report.html` - Full HTML report
  - `health-report.md` - Markdown version
  - `health-report.json` - Machine-readable summary
- **Delivery:** SMTPS (port 465) via Mailu with authentication
- **Schedule:** Daily at 7:00 AM UTC via cron
