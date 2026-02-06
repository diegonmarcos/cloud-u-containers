# Windmill Workflow Orchestration

> **Deployment:** oci-f-micro_2 (129.151.228.66)
> **Access:** https://windmill.diegonmarcos.com
> **Resources:** ~400-600 MB RAM (server + worker + postgres)

## Overview

Windmill is a workflow orchestration platform that allows you to automate tasks across your cloud infrastructure.

**Use Cases:**
- Schedule backups of Matomo database
- Automate service restarts across VMs
- Monitor service health and send alerts
- Execute workflows triggered by webhooks
- Orchestrate Docker containers via SSH

---

## Quick Start

### 1. Generate Database Password

```bash
# Generate secure password
openssl rand -base64 32 > secrets/db_password.txt

# Verify
cat secrets/db_password.txt
```

### 2. Configure Environment

```bash
# Copy example env file (already done)
# Edit env/windmill.env if needed
nano env/windmill.env

# Set BASE_URL and COOKIE_DOMAIN (already configured)
```

### 3. Deploy

```bash
# Start services
docker compose up -d

# View logs
docker compose logs -f

# Check status
docker compose ps
```

### 4. Access UI

Navigate to: **https://windmill.diegonmarcos.com**

**First-time setup:**
1. Create admin account
2. Configure workspace
3. Start creating workflows

---

## Architecture

```
┌─────────────────────────────────────────────┐
│ oci-f-micro_2 (129.151.228.66)            │
├─────────────────────────────────────────────┤
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │  NPM (Nginx Proxy Manager)          │   │
│  │  Port 443 → windmill-server:8000    │   │
│  └────────────────┬────────────────────┘   │
│                   │                         │
│  ┌────────────────▼────────────────────┐   │
│  │  windmill-server                    │   │
│  │  - API & UI                         │   │
│  │  - Job scheduling                   │   │
│  │  - Port 8000 (localhost only)       │   │
│  │  - 128-256 MB RAM                   │   │
│  └────────────────┬────────────────────┘   │
│                   │                         │
│  ┌────────────────▼────────────────────┐   │
│  │  windmill-worker                    │   │
│  │  - Executes workflows               │   │
│  │  - SSH to VMs                       │   │
│  │  - Docker API access                │   │
│  │  - 128-256 MB RAM                   │   │
│  └────────────────┬────────────────────┘   │
│                   │                         │
│  ┌────────────────▼────────────────────┐   │
│  │  windmill-db (PostgreSQL)           │   │
│  │  - Stores workflows & logs          │   │
│  │  - 64-128 MB RAM                    │   │
│  └─────────────────────────────────────┘   │
│                                             │
└─────────────────────────────────────────────┘
```

---

## Resource Usage

| Component | RAM (Est) | Storage (Est) | CPU |
|-----------|-----------|---------------|-----|
| windmill-server | 128-256 MB | 100-500 MB | 0.5 vCPU |
| windmill-worker | 128-256 MB | 100-500 MB | 0.5 vCPU |
| windmill-db | 64-128 MB | 500 MB-2 GB | 0.1 vCPU |
| **TOTAL** | **320-640 MB** | **1-3 GB** | **1.1 vCPU** |

**Notes:**
- Resource limits configured for 1GB VM with swap
- Worker spawns temporary containers for jobs (additional RAM)
- Database grows with workflow logs (configure retention policy)

---

## NPM Reverse Proxy Configuration

**Add to NPM on oci-f-micro_2:**

1. **Create Proxy Host:**
   - Domain: `windmill.diegonmarcos.com`
   - Scheme: `http`
   - Forward Hostname/IP: `windmill-server` (or `127.0.0.1`)
   - Forward Port: `8000`
   - Enable WebSocket Support: ✅
   - SSL: Request Let's Encrypt certificate

2. **Optional: Add Authelia Protection:**
   - Advanced → Custom Nginx Configuration:
   ```nginx
   location /api/auth/verify {
       internal;
       proxy_pass http://authelia:9091/api/verify;
   }
   ```

---

## Common Workflows

### Example 1: Backup Matomo Database

```python
# Windmill script: backup_matomo.py
import paramiko
import datetime

def main():
    # SSH to oci-f-micro_2
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect('127.0.0.1', username='ubuntu', key_filename='/home/windmill/.ssh/id_rsa')

    # Create backup
    timestamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    backup_file = f"/tmp/matomo_backup_{timestamp}.sql"

    command = f"docker exec analytics-db mysqldump -u matomo -p matomo > {backup_file}"
    stdin, stdout, stderr = ssh.exec_command(command)

    return f"Backup created: {backup_file}"
```

**Schedule:** Daily at 2:00 AM UTC

---

### Example 2: Health Check All Services

```python
# Windmill script: health_check.py
import requests
import paramiko

def main():
    services = {
        'Matomo': 'https://analytics.diegonmarcos.com',
        'Mail': 'https://mail.diegonmarcos.com',
        'Photos': 'https://photos.diegonmarcos.com',
    }

    results = {}
    for name, url in services.items():
        try:
            r = requests.get(url, timeout=10)
            results[name] = 'OK' if r.status_code == 200 else f'ERROR {r.status_code}'
        except Exception as e:
            results[name] = f'DOWN: {str(e)}'

    return results
```

**Schedule:** Every 5 minutes

---

### Example 3: Restart Service on Flex VM

```python
# Windmill script: restart_photoprism.py
import paramiko

def main(service_name: str = 'photoprism_app'):
    # SSH via WireGuard to flex VM
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    # Connect via GCP hub first (WireGuard gateway)
    ssh.connect('35.226.147.64', username='diego', key_filename='/home/windmill/.ssh/google_compute_engine')

    # From GCP, SSH to flex VM via WireGuard
    command = f"ssh ubuntu@10.0.0.2 'docker restart {service_name}'"
    stdin, stdout, stderr = ssh.exec_command(command)

    return f"Service {service_name} restarted: {stdout.read().decode()}"
```

**Trigger:** On-demand or scheduled

---

## Management Commands

### Start/Stop/Restart

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# Restart specific service
docker compose restart windmill-server

# View logs
docker compose logs -f windmill-server

# Check resource usage
docker stats windmill-server windmill-worker windmill-db
```

### Database Management

```bash
# Access PostgreSQL
docker exec -it windmill-db psql -U windmill -d windmill

# Backup database
docker exec windmill-db pg_dump -U windmill windmill > windmill_backup.sql

# Restore database
docker exec -i windmill-db psql -U windmill windmill < windmill_backup.sql

# Clean old job logs (reduce database size)
docker exec -it windmill-db psql -U windmill -d windmill -c "DELETE FROM completed_job WHERE created_at < NOW() - INTERVAL '30 days';"
```

### Updates

```bash
# Pull latest images
docker compose pull

# Restart with new images
docker compose up -d

# View version
docker exec windmill-server curl -s http://localhost:8000/api/version
```

---

## Troubleshooting

### High Memory Usage

```bash
# Check current usage
free -h
docker stats --no-stream

# Reduce worker count (edit env/windmill.env)
NUM_WORKERS=1

# Restart
docker compose restart windmill-worker
```

### Database Growing Too Large

```bash
# Check database size
docker exec windmill-db psql -U windmill -c "SELECT pg_size_pretty(pg_database_size('windmill'));"

# Clean old logs (keep last 7 days)
docker exec windmill-db psql -U windmill -d windmill -c "DELETE FROM completed_job WHERE created_at < NOW() - INTERVAL '7 days';"

# Vacuum database
docker exec windmill-db psql -U windmill -d windmill -c "VACUUM FULL;"
```

### Worker Not Picking Up Jobs

```bash
# Check worker logs
docker compose logs windmill-worker

# Restart worker
docker compose restart windmill-worker

# Verify database connection
docker exec windmill-worker env | grep DATABASE_URL
```

---

## Security Considerations

1. **Database Password:**
   - Use strong random password (generated above)
   - Never commit `secrets/db_password.txt` to git

2. **SSH Keys:**
   - Worker mounts `/home/ubuntu/.ssh` read-only
   - Ensure proper key permissions (600)

3. **Network Isolation:**
   - Windmill services on isolated `windmill-net` network
   - Only server exposes port (localhost only)
   - NPM handles SSL/TLS termination

4. **Docker Socket Access:**
   - Worker has access to `/var/run/docker.sock`
   - Required for job execution but powerful
   - Ensure Windmill admin access is restricted

5. **Authelia Protection (Optional):**
   - Consider adding 2FA via Authelia
   - Protects admin panel from unauthorized access

---

## Integration with Existing Services

### SSH Access to VMs

**Windmill can SSH to all your VMs:**
- oci-f-micro_1 (130.110.251.193) - Mail
- oci-f-micro_2 (127.0.0.1) - Local (Matomo + Windmill)
- oci-p-flex_1 via GCP hub (10.0.0.2) - Flex VM
- gcp-f-micro_1 (35.226.147.64) - Central Hub

**SSH via WireGuard:**
```python
# Connect via GCP hub to access WireGuard network
ssh_hub = connect('35.226.147.64', username='diego')
ssh_hub.exec_command('ssh ubuntu@10.0.0.2 "docker ps"')
```

### Webhook Integration

**Receive webhooks from services:**
```python
# Windmill HTTP endpoint
POST /api/w/workspace_id/jobs/run/script_path
Authorization: Bearer <token>

# Example: Photoprism sends webhook on new upload
{
  "event": "photo.uploaded",
  "photo_id": "12345",
  "timestamp": "2026-02-06T12:00:00Z"
}
```

---

## Monitoring

### Metrics (Disabled by Default)

Metrics are disabled to save resources. To enable:

```bash
# Edit env/windmill.env
METRICS_ENABLED=true

# Restart
docker compose restart
```

### Health Checks

```bash
# Server health
curl http://localhost:8000/api/version

# Database health
docker exec windmill-db pg_isready -U windmill

# Worker health
docker compose ps windmill-worker
```

---

## Backup & Recovery

### Backup Windmill

```bash
# Create backup script
cat > backup_windmill.sh << 'EOF'
#!/bin/bash
BACKUP_DIR=/backup/windmill
DATE=$(date +%Y%m%d_%H%M%S)

# Create backup directory
mkdir -p $BACKUP_DIR

# Backup database
docker exec windmill-db pg_dump -U windmill windmill | gzip > $BACKUP_DIR/windmill_db_$DATE.sql.gz

# Backup volumes (workflows, logs)
docker run --rm -v windmill-server-data:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/windmill_data_$DATE.tar.gz /data

echo "Backup complete: $BACKUP_DIR"
EOF

chmod +x backup_windmill.sh
./backup_windmill.sh
```

### Restore Windmill

```bash
# Stop services
docker compose down

# Restore database
gunzip -c windmill_db_20260206_120000.sql.gz | docker exec -i windmill-db psql -U windmill windmill

# Restore volumes
docker run --rm -v windmill-server-data:/data -v $(pwd):/backup alpine tar xzf /backup/windmill_data_20260206_120000.tar.gz -C /

# Start services
docker compose up -d
```

---

## Next Steps

1. ✅ Generate database password
2. ✅ Deploy with `docker compose up -d`
3. ⏳ Configure NPM reverse proxy
4. ⏳ Access UI and create admin account
5. ⏳ Create first workflow (e.g., backup Matomo)
6. ⏳ Set up scheduled tasks
7. ⏳ (Optional) Add Authelia 2FA protection

---

## Resources

- **Windmill Docs:** https://docs.windmill.dev
- **Docker Hub:** https://hub.docker.com/r/windmillhub/windmill
- **GitHub:** https://github.com/windmill-labs/windmill
- **Discord:** https://discord.gg/windmill
