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
│  │ MD Report  │  │ Console    │  │ Email via  │           │
│  │ (stored)   │  │ Output     │  │ SMTP Proxy │           │
│  └────────────┘  └────────────┘  └────────────┘           │
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
| `SMTP_PROXY_URL` | http://smtp.diegonmarcos.com:8080/ | Email endpoint |
| `SMTP_PROXY_KEY` | stalwart-proxy-key-2025 | API key |
| `OCI_MICRO_1` | 130.110.251.193 | Mail server IP |
| `OCI_MICRO_2` | 129.151.228.66 | Analytics IP |
| `GCP_MICRO_1` | 35.226.147.64 | Proxy IP |
| `OCI_FLEX_1` | 84.235.234.87 | Photos IP |

## Usage

### Manual Run
```bash
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
- **Body:** Full Markdown report
