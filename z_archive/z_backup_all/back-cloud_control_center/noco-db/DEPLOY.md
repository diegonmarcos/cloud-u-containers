# NocoDB Deployment Guide

## Quick Start

```bash
cd /home/diego/Mounts/Git/cloud/a_solutions/back-data_know_center/noco-db

# Full automated deployment
./1.ops/deploy.sh full
```

## Overview

| Property | Value |
|----------|-------|
| **Service** | NocoDB (Open Source Airtable Alternative) |
| **VM** | oci-p-flex_1 (144.24.196.72) |
| **WireGuard IP** | 10.0.0.2 |
| **Internal Port** | 8085 |
| **Public URL** | https://db.diegonmarcos.com |
| **Auth** | Authelia 2FA |
| **Database** | PostgreSQL 16 (dedicated) |
| **Network** | nocodb_network (172.25.0.0/24) |

## Deployment Checklist

### Phase 1: VM Preparation

- [x] Ensure oci-p-flex_1 is running (wake from Oracle Console if needed)
- [x] Verify SSH connectivity: `./1.ops/deploy.sh check`

### Phase 2: Deploy Containers

- [x] Run full deployment: `./1.ops/deploy.sh full`
- [x] Save credentials to Bitwarden (displayed during deployment)
- [x] Verify containers running: `./1.ops/deploy.sh status`

**Deployed:** 2026-02-03

### Phase 3: Network Configuration

- [ ] **Cloudflare DNS**: Add A record `db` → `35.226.147.64` (proxied)
  - See: `1.ops/cloudflare_dns.md`

- [ ] **NPM Proxy Host**: Create proxy for db.diegonmarcos.com
  - See: `1.ops/npm_config.md`
  - Domain: db.diegonmarcos.com
  - Forward: 10.0.0.2:8085
  - Enable SSL + Authelia

- [ ] **Authelia Rule**: Add 2FA policy for db.diegonmarcos.com
  - See: `1.ops/authelia_config.yml`

### Phase 4: Verification

- [ ] Test URL: https://db.diegonmarcos.com
- [ ] Verify Authelia redirect works
- [ ] Complete 2FA login
- [ ] Access NocoDB dashboard

### Phase 5: Documentation

- [ ] Update `cloud_architecture.json` with new service
  - See: `1.ops/cloud_architecture_update.json`

## Deploy Script Commands

```bash
./1.ops/deploy.sh <command>

Commands:
  check       Check VM connectivity
  upload      Upload files to server
  init-env    Generate .env file on server
  deploy      Deploy containers
  full        Full deployment (all above steps)
  status      Show container status
  logs [c]    Follow container logs
  stop        Stop containers
  restart     Restart containers
  backup      Backup PostgreSQL database
  destroy     Remove all data (dangerous!)
```

## Manual Deployment

If the script fails, deploy manually:

### 1. SSH to Server

```bash
ssh -i ~/Mounts/Git/vault/A0_keys/ssh/id_rsa ubuntu@144.24.196.72
```

### 2. Create Directory & Files

```bash
mkdir -p ~/nocodb && cd ~/nocodb

# Copy docker-compose.yml (from local)
# Or create manually - see docker-compose.yml in this repo
```

### 3. Generate Environment

```bash
cat > .env << EOF
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
NC_AUTH_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/+=')
NC_ADMIN_EMAIL=diego@diegonmarcos.com
NC_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')
EOF

# Display and save to Bitwarden!
cat .env
```

### 4. Deploy

```bash
sudo docker compose pull
sudo docker compose up -d
sudo docker ps | grep nocodb
```

## Troubleshooting

### VM Not Reachable

```bash
# Check if VM is running
ping 144.24.196.72

# If not, start from Oracle Console:
# https://cloud.oracle.com → Compute → Instances → oci-p-flex_1 → Start
```

### Container Issues

```bash
# View logs
./1.ops/deploy.sh logs nocodb
./1.ops/deploy.sh logs nocodb-db

# Restart
./1.ops/deploy.sh restart
```

### Database Connection Failed

```bash
# Check PostgreSQL is healthy
ssh ubuntu@144.24.196.72 "sudo docker exec nocodb-db pg_isready"

# Check environment variables
ssh ubuntu@144.24.196.72 "sudo docker exec nocodb env | grep NC_DB"
```

### WireGuard Connectivity

```bash
# From GCP (NPM server), test WireGuard
gcloud compute ssh arch-1 --zone=us-central1-a --command="ping -c 3 10.0.0.2"

# Check WireGuard status on OCI
ssh ubuntu@144.24.196.72 "sudo wg show"
```

## Backup & Restore

### Create Backup

```bash
./1.ops/deploy.sh backup
# Saves to backups/nocodb_backup_YYYYMMDD_HHMMSS.sql
```

### Restore Backup

```bash
ssh ubuntu@144.24.196.72
cat backup.sql | sudo docker exec -i nocodb-db psql -U nocodb -d nocodb
```

## Resource Usage

| Container | RAM | Storage |
|-----------|-----|---------|
| nocodb | 256-512 MB | 100 MB - 5 GB |
| nocodb-db | 128-256 MB | 500 MB - 10 GB |
| **Total** | ~400-800 MB | ~1-15 GB |

## External Database Connections

After deployment, connect NocoDB to existing databases:

1. Open https://db.diegonmarcos.com
2. Go to **Bases** → **Connect External Database**
3. Use WireGuard IPs for connection:

| Database | Host | Port | Database | User |
|----------|------|------|----------|------|
| Matomo | 10.0.0.4 | 3306 | matomo | matomo |
| Photoprism | localhost | 3306 | photoprism | photoprism |

### SQLite Databases via Postlite

SQLite databases can be accessed as PostgreSQL connections via postlite:

| Database | Host | Port | User | Password | Notes |
|----------|------|------|------|----------|-------|
| NPM | 35.226.147.64 | 5433 | any | any | GCloud sqlite |
| Vaultwarden | 35.226.147.64 | 5434 | any | any | GCloud sqlite |
| ntfy | 35.226.147.64 | 5435 | any | any | GCloud sqlite |

**Note:** Postlite accepts any credentials - it's just a protocol bridge.

## CLI/API Access with Bearer Tokens

NocoDB supports Bearer token authentication for CLI/API access via the Introspect Proxy.

### Get Token

```bash
# 1. Open in browser
open "https://auth.diegonmarcos.com/api/oidc/authorization?client_id=cli&response_type=code&scope=openid%20profile%20email&redirect_uri=http://localhost:8085/callback"

# 2. Login + 2FA, copy code from redirect URL

# 3. Exchange for token
curl -X POST https://auth.diegonmarcos.com/api/oidc/token \
  -u "cli:<redacted-secret>" \
  -d "grant_type=authorization_code&code=<YOUR_CODE>&redirect_uri=http://localhost:8085/callback"
```

### Use Token

```bash
TOKEN="eyJhbGc..."

# List bases
curl -H "Authorization: Bearer $TOKEN" \
  https://db.diegonmarcos.com/api/v2/meta/bases

# List tables in a base
curl -H "Authorization: Bearer $TOKEN" \
  https://db.diegonmarcos.com/api/v2/meta/bases/{baseId}/tables
```

**Reference:** See Cloud-spec.md Section 14.8 for full documentation.
