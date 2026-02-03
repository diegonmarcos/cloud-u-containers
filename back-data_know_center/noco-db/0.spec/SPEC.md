# NocoDB Service Specification

> **Version**: 1.0.0 | **Status**: Planned | **VM**: oci-p-flex_1

## Overview

NocoDB is an open-source Airtable alternative that turns any database into a smart spreadsheet. It will serve as the central data integration hub for all cloud services.

## Service Card

| Property | Value |
|----------|-------|
| **Service ID** | nocodb |
| **Display Name** | NocoDB Database UI |
| **Category** | data |
| **VM** | oci-p-flex_1 (144.24.196.72) |
| **WireGuard IP** | 10.0.0.2 |
| **Internal Port** | 8085 |
| **Public URL** | https://db.diegonmarcos.com |
| **Auth** | Authelia 2FA |
| **Database** | PostgreSQL 16 (dedicated) |
| **Network** | nocodb_network (172.25.0.0/24) |

## Resource Requirements

| Container | Image | RAM | Storage | CPU |
|-----------|-------|-----|---------|-----|
| nocodb | nocodb/nocodb:latest | 256-512 MB | 100 MB - 5 GB | 0.25-0.5 |
| nocodb-db | postgres:16-alpine | 128-256 MB | 500 MB - 10 GB | 0.1-0.25 |
| **Total** | | ~400-800 MB | ~1-15 GB | ~0.35-0.75 |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                    │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │ HTTPS (443)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    GCP Free Micro 1 (35.226.147.64)                      │
│  ┌─────────────┐    ┌─────────────────┐                                 │
│  │     NPM     │───▶│    Authelia     │                                 │
│  │  SSL Proxy  │    │   2FA + TOTP    │                                 │
│  └──────┬──────┘    └─────────────────┘                                 │
└─────────┼───────────────────────────────────────────────────────────────┘
          │ WireGuard (10.0.0.1 → 10.0.0.2)
          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    OCI Paid Flex 1 (144.24.196.72)                       │
│                    WireGuard: 10.0.0.2                                   │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    nocodb_network (172.25.0.0/24)                  │  │
│  │                                                                    │  │
│  │  ┌─────────────────┐         ┌─────────────────┐                  │  │
│  │  │     nocodb      │────────▶│   nocodb-db     │                  │  │
│  │  │   :8085→:8080   │   pg    │   PostgreSQL    │                  │  │
│  │  │   (App Server)  │         │   :5432         │                  │  │
│  │  └─────────────────┘         └─────────────────┘                  │  │
│  │                                                                    │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  Existing Services:                                                      │
│  ├── Photoprism (photos_network)                                        │
│  ├── Radicale (calendar)                                                │
│  └── Redis (cache)                                                      │
└─────────────────────────────────────────────────────────────────────────┘
```

## External Database Connections

NocoDB can connect to existing databases to provide a unified UI:

| Database | VM | WireGuard IP | Port | Use Case |
|----------|-----|--------------|------|----------|
| Matomo MariaDB | oci-f-micro_2 | 10.0.0.4 | 3306 | Analytics data |
| Photoprism MariaDB | oci-p-flex_1 | localhost | 3306 | Photo metadata |
| Mailu SQLite | oci-f-micro_1 | N/A | File | Mail accounts (read-only) |

## Security Model

```
Layer 1: Cloudflare (DDoS, WAF)
    ↓
Layer 2: NPM (SSL termination, rate limiting)
    ↓
Layer 3: Authelia (2FA authentication)
    ↓
Layer 4: WireGuard (encrypted tunnel)
    ↓
Layer 5: Docker Network Isolation
    ↓
Layer 6: NocoDB App (JWT auth, RBAC)
```

## Data Flow

### Read Path
```
User → Cloudflare → NPM → Authelia → WireGuard → NocoDB → PostgreSQL
                                                      ↓
                                              External DBs (via WireGuard)
```

### Write Path
```
User Form → NocoDB API → PostgreSQL (primary)
                    ↓
            Webhook/Automation → External Services
```

## Integration Points

| Integration | Type | Direction | Purpose |
|-------------|------|-----------|---------|
| Matomo | Database Link | Read | View analytics data |
| Photoprism | Database Link | Read | Photo metadata queries |
| ntfy | Webhook | Out | Notifications on data changes |
| Cloud API | REST | Bidirectional | Dashboard data |
| Authelia | Proxy Auth | In | SSO user info |

## Backup Strategy

| Component | Method | Frequency | Retention |
|-----------|--------|-----------|-----------|
| PostgreSQL | pg_dump | Daily | 7 days |
| NocoDB Data | Volume snapshot | Weekly | 4 weeks |

## Monitoring

| Metric | Check | Alert Threshold |
|--------|-------|-----------------|
| HTTP Health | `/api/v1/health` | 5xx or timeout |
| Container Status | Docker healthcheck | unhealthy |
| Disk Usage | Volume size | >80% |
| Memory | Container stats | >90% |

## Future Considerations

1. **API Integration**: Expose NocoDB API for external tools
2. **Sync**: Bidirectional sync with external services
3. **Automation**: n8n/Zapier-style workflows
4. **Mobile**: PWA access via mobile devices
