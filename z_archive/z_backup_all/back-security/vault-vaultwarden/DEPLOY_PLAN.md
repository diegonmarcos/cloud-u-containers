# Vaultwarden Deployment Plan

> **Target Domain**: vault.diegonmarcos.com
> **Status**: Planning
> **Last Updated**: 2026-02-02

---

## 1. RAM Analysis (Verified 2026-02-02)

### Actual Usage

| VM | Total | Used | Free | Available | Swap Used | **Verdict** |
|----|-------|------|------|-----------|-----------|-------------|
| **gcp-f-micro_1** | 945 MB | 548 MB | 189 MB | **397 MB** | 196 MB | ✅ Best choice |
| oci-f-micro_1 | 956 MB | 688 MB | 79 MB | 268 MB | 919 MB | ❌ Too tight |
| oci-f-micro_2 | 956 MB | 822 MB | 75 MB | 134 MB | 0 (none) | ❌ Too tight |

### Docker Container Memory (per VM)

**gcp-f-micro_1** (~133 MB total):
| Container | RAM |
|-----------|-----|
| flask-api | 60.5 MB |
| npm | 27.0 MB |
| authelia | 18.9 MB |
| ntfy | 10.7 MB |
| github-rss | 5.7 MB |
| syslog-central | 4.4 MB |
| syslog-bridge | 3.5 MB |
| authelia-redis | 2.0 MB |
| palantir-cron | 0.6 MB |

**oci-f-micro_1** (~125 MB docker, but 919 MB swap = memory pressure):
- Mailu stack + radicale + syncthing + matomo-app + nginx-proxy

**oci-f-micro_2** (~442 MB docker):
- matomo-app: 334 MB
- matomo-db: 90 MB
- syslog-forwarder: 18 MB

### Vaultwarden Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 50 MB | 100 MB |
| Storage | 50 MB | 100 MB + attachments |
| CPU | Minimal | Minimal |

---

## 2. Recommended Deployment Target

**Primary Choice: `gcp-f-micro_1`** (Proxy server)

Reasons:
- Already hosts authentication (Authelia) - logical grouping
- NPM already configured for proxying
- More predictable RAM usage than OCI Micro 1 (Mailu is RAM-heavy)
- Static IP (35.226.147.64)

**Alternative: `oci-f-micro_2`** if GCP is too tight on RAM.

---

## 3. Pre-Deployment Checklist

- [ ] Verify RAM availability (need ~100 MB free)
- [ ] Create DNS record: `vault.diegonmarcos.com` → 35.226.147.64
- [ ] Prepare admin token (generate with: `openssl rand -base64 48`)
- [ ] Backup current Bitwarden cloud data (Settings → Export Vault)

---

## 4. Deployment Files

### 4.1 docker-compose.yml

```yaml
version: "3.8"

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - DOMAIN=https://vault.diegonmarcos.com
      - SIGNUPS_ALLOWED=false
      - INVITATIONS_ALLOWED=false
      - SHOW_PASSWORD_HINT=false
      - ADMIN_TOKEN=${ADMIN_TOKEN}
      - WEBSOCKET_ENABLED=true
      - LOG_LEVEL=warn
      # Optional: SMTP for email notifications
      # - SMTP_HOST=mail.diegonmarcos.com
      # - SMTP_FROM=vault@diegonmarcos.com
      # - SMTP_PORT=587
      # - SMTP_SECURITY=starttls
      # - SMTP_USERNAME=vault@diegonmarcos.com
      # - SMTP_PASSWORD=${SMTP_PASSWORD}
    volumes:
      - ./data:/data
    networks:
      - npm_default
    # No port exposure - NPM handles SSL termination
    # ports:
    #   - "127.0.0.1:8080:80"

networks:
  npm_default:
    external: true
```

### 4.2 .env (DO NOT COMMIT - add to .gitignore)

```bash
# Generate with: openssl rand -base64 48
ADMIN_TOKEN=your_secure_admin_token_here

# Optional: for email notifications via Mailu
# SMTP_PASSWORD=your_smtp_password
```

### 4.3 .gitignore

```
.env
data/
```

---

## 5. NPM Proxy Configuration

Create new Proxy Host in NPM (proxy.diegonmarcos.com:81):

| Field | Value |
|-------|-------|
| Domain | vault.diegonmarcos.com |
| Scheme | http |
| Forward Hostname | vaultwarden |
| Forward Port | 80 |
| Websockets Support | ✅ Enabled |
| SSL | Request new Let's Encrypt cert |
| Force SSL | ✅ Enabled |
| HTTP/2 | ✅ Enabled |

**Custom Nginx Configuration** (Advanced tab):
```nginx
# Allow large attachment uploads
client_max_body_size 128M;
```

---

## 6. Deployment Steps

### Step 1: DNS Setup (Cloudflare)
```
Type: A
Name: vault
Content: 35.226.147.64
Proxy: OFF (DNS only - NPM handles SSL)
TTL: Auto
```

### Step 2: Deploy on GCP
```bash
# SSH to GCP
gcloud compute ssh arch-1 --zone us-central1-a

# Create directory
mkdir -p ~/vaultwarden && cd ~/vaultwarden

# Create docker-compose.yml (copy from section 4.1)
nano docker-compose.yml

# Create .env with admin token
echo "ADMIN_TOKEN=$(openssl rand -base64 48)" > .env

# Start container
docker compose up -d

# Verify
docker logs vaultwarden
```

### Step 3: Configure NPM
1. Access NPM: https://proxy.diegonmarcos.com
2. Add Proxy Host as per Section 5
3. Wait for SSL certificate

### Step 4: Initial Setup
1. Navigate to https://vault.diegonmarcos.com
2. Create your account (first user)
3. Access admin panel: https://vault.diegonmarcos.com/admin
4. Disable signups in admin panel (redundant but safe)

### Step 5: Import Data
1. Export from Bitwarden cloud (JSON format)
2. Import in Vaultwarden: Tools → Import Data

### Step 6: Configure Clients
- **Browser Extension**: Settings → Self-hosted → https://vault.diegonmarcos.com
- **Android App**: Gear icon → Self-hosted → https://vault.diegonmarcos.com
- **Desktop App**: Settings → Self-hosted → https://vault.diegonmarcos.com

---

## 7. Authelia Integration (Optional)

If you want 2FA via Authelia before accessing Vaultwarden admin:

Add to NPM Advanced config for vault.diegonmarcos.com:
```nginx
location /admin {
    # Authelia protection for admin panel
    include /etc/nginx/snippets/authelia-location.conf;
    proxy_pass http://vaultwarden:80;
}
```

Note: Regular vault access should NOT go through Authelia (apps can't handle it).

---

## 8. Backup Strategy

### Automatic Backup Script

Create `/home/ubuntu/scripts/backup-vaultwarden.sh`:
```bash
#!/bin/bash
BACKUP_DIR="/home/ubuntu/backups/vaultwarden"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# Stop container for consistent backup
docker stop vaultwarden

# Backup data directory
tar -czf "$BACKUP_DIR/vaultwarden_$DATE.tar.gz" -C /home/ubuntu/vaultwarden data/

# Restart container
docker start vaultwarden

# Keep only last 7 backups
ls -t "$BACKUP_DIR"/*.tar.gz | tail -n +8 | xargs -r rm

echo "Backup completed: vaultwarden_$DATE.tar.gz"
```

### Cron Schedule
```bash
# Weekly backup - Sunday 3 AM
0 3 * * 0 /home/ubuntu/scripts/backup-vaultwarden.sh >> /var/log/vaultwarden-backup.log 2>&1
```

---

## 9. Monitoring

Add to your monitoring stack:
```bash
# Health check
curl -s https://vault.diegonmarcos.com/alive | grep -q "true"

# Container status
docker inspect vaultwarden --format='{{.State.Status}}'
```

---

## 10. Security Hardening

Already configured in docker-compose.yml:
- ✅ `SIGNUPS_ALLOWED=false` - No public registration
- ✅ `INVITATIONS_ALLOWED=false` - No invite system
- ✅ `SHOW_PASSWORD_HINT=false` - No hint leakage
- ✅ No direct port exposure - NPM proxy only
- ✅ HTTPS enforced via NPM

Additional recommendations:
- [ ] Enable 2FA on your Vaultwarden account immediately
- [ ] Use Argon2 for master password (default in recent versions)
- [ ] Regular backups to external location
- [ ] Consider IP whitelist in NPM for /admin endpoint

---

## 11. Rollback Plan

If deployment fails:
```bash
# Stop and remove
docker compose down

# Remove data (if fresh install)
rm -rf ./data

# Clients automatically fall back to last working server
# Reconfigure clients back to Bitwarden cloud if needed
```

---

## 12. Post-Deployment Verification

- [ ] Web vault accessible at https://vault.diegonmarcos.com
- [ ] Can create/view passwords
- [ ] Browser extension syncs
- [ ] Android app syncs
- [ ] Passkeys work (create test passkey)
- [ ] Admin panel accessible with token
- [ ] Backup script runs successfully
- [ ] WebSocket connection working (real-time sync)
