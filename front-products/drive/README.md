# AFFiNE Deployment

**Privacy-first workspace** - Alternative to Notion, Miro, Monday.com

## Service Information

| Property | Value |
|----------|-------|
| **Public URL** | https://drive-notes-affine.diegonmarcos.com |
| **VM** | oci-p-flex_1 (Oracle Flex) |
| **Availability** | Wake-on-Demand |
| **Internal Port** | 3010 |
| **Docker Network** | dev_network (172.24.0.0/24) |

## Architecture

AFFiNE is deployed as a 3-container stack:

1. **affine_app** - Main application (Node.js/TypeScript)
   - Port 3010
   - Block-based editor (BlockSuite engine)
   - Page mode + Edgeless (whiteboard) mode
   - CRDT-based collaboration (OctoBase)

2. **affine_postgres** - PostgreSQL 16 database
   - Stores workspace data, users, metadata
   - Volume: `postgres_data`

3. **affine_redis** - Redis cache
   - Session management
   - Real-time collaboration state
   - Volume: `redis_data`

## Key Features

- **Hyper-merged workflow**: Switch between docs and whiteboard
- **Local-first**: Data stored locally, syncs when online
- **Block-based editing**: Every element is a draggable block
- **Offline-capable**: Works without internet connection
- **Self-hosted**: Full control over your data

## Tech Stack

- **Frontend**: TypeScript + React
- **Backend**: Node.js + Rust (performance-critical parts)
- **Storage**: PostgreSQL + local file system
- **Collaboration**: CRDTs (Conflict-free Replicated Data Types)

## Deployment Commands

### SSH to Oracle Flex VM
```bash
ssh -i /home/diego/usr_vault/A0_keys/ssh/id_rsa ubuntu@84.235.234.87
```

### Deploy AFFiNE
```bash
cd /opt/affine
docker compose up -d
```

### View Logs
```bash
docker compose logs -f affine
docker compose logs -f postgres
docker compose logs -f redis
```

### Check Status
```bash
docker compose ps
docker stats --no-stream affine_app affine_postgres affine_redis
```

### Stop/Restart
```bash
docker compose down
docker compose restart affine
```

### Backup Data
```bash
# Backup PostgreSQL
docker exec affine_postgres pg_dump -U affine affine > backup_$(date +%Y%m%d).sql

# Backup volumes
docker run --rm -v affine_storage:/data -v $(pwd):/backup alpine tar czf /backup/affine_storage_$(date +%Y%m%d).tar.gz -C /data .
```

## NPM Proxy Configuration

**On gcp-f-micro_1 (NPM Admin: http://35.226.147.64:81)**

1. Add Proxy Host:
   - **Domain**: drive-notes-affine.diegonmarcos.com
   - **Forward Hostname/IP**: 84.235.234.87
   - **Forward Port**: 3010
   - **Scheme**: http
   - **SSL**: Request Let's Encrypt certificate
   - **Force SSL**: ON
   - **HTTP/2**: ON

2. Custom Nginx Config (Advanced tab):
   ```nginx
   # WebSocket support for real-time collaboration
   proxy_set_header Upgrade $http_upgrade;
   proxy_set_header Connection "upgrade";

   # Increase timeouts for long-lived connections
   proxy_read_timeout 3600s;
   proxy_send_timeout 3600s;
   ```

## Initial Setup

1. **Start Oracle Flex VM** (if not running)
   - Go to cloud.oracle.com
   - Navigate to Compute → Instances → eu-marseille-1
   - Start `oci-p-flex_1`

2. **Copy deployment files to VM**
   ```bash
   scp -i /home/diego/usr_vault/A0_keys/ssh/id_rsa \
     docker-compose.yml .env \
     ubuntu@84.235.234.87:/opt/affine/
   ```

3. **Deploy on VM**
   ```bash
   ssh -i /home/diego/usr_vault/A0_keys/ssh/id_rsa ubuntu@84.235.234.87
   cd /opt/affine
   docker network create dev_network  # if not exists
   docker compose up -d
   ```

4. **Configure NPM** (see above)

5. **Access AFFiNE**
   - URL: https://drive-notes-affine.diegonmarcos.com
   - First visit will create admin account
   - Use credentials from `.env` file

## Security Notes

- **Change default password** in `.env` before deploying
- AFFiNE admin email: Set in `AFFINE_ADMIN_EMAIL`
- Database password: Currently `affine` (consider changing in production)
- NPM handles SSL/TLS termination
- Consider enabling Authelia 2FA for additional security

## Resource Usage

Expected resource consumption:
- **RAM**: ~800MB total (app: 500MB, postgres: 200MB, redis: 100MB)
- **Disk**: ~2GB for Docker images + user data growth
- **CPU**: Low idle, moderate during active collaboration

## Troubleshooting

### Container won't start
```bash
docker compose logs affine
```

### Database connection errors
```bash
docker compose logs postgres
# Check if postgres is healthy
docker compose ps
```

### Can't access via domain
1. Check NPM proxy host is configured
2. Verify Oracle Flex VM firewall allows port 3010
3. Check container is running: `docker ps | grep affine`

### Port 3010 conflicts
- Check existing services: `sudo netstat -tlnp | grep 3010`
- Update port in `docker-compose.yml` if needed

## Cost Impact

- **VM Cost**: $5.50/month (same as before - wake-on-demand)
- **Additional Docker Images**: ~2GB storage (no extra cost)
- **Bandwidth**: Negligible for personal use

## References

- **GitHub**: https://github.com/toeverything/AFFiNE
- **Official Docs**: https://affine.pro
- **Live Demo**: https://app.affine.pro
- **Self-hosting Guide**: https://docs.affine.pro/docs/self-host-affine

---

**Deployment Date**: 2026-01-09
**Deployed By**: Diego Nepomuceno Marcos
**Status**: Pending VM startup and deployment
