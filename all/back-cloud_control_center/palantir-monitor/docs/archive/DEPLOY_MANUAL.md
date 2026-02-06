# Palantir Monitor - Manual Deployment Guide

## Quick Deploy (Copy-Paste Commands)

Run these commands from your Termux terminal:

### Step 1: SSH to Mail Server
```bash
ssh -i ~/vault/A0_keys/ssh/id_rsa ubuntu@130.110.251.193
```

### Step 2: Create Deployment Directory
```bash
sudo mkdir -p /opt/palantir-monitor
sudo chown ubuntu:ubuntu /opt/palantir-monitor
cd /opt/palantir-monitor
```

### Step 3: Copy Files from Local Machine

**Exit SSH and run from Termux:**
```bash
cd ~/Git/cloud/a_solutions/back-security/palantir-monitor

rsync -avz -e "ssh -i ~/vault/A0_keys/ssh/id_rsa" \
    --exclude '.git' \
    --exclude '*.log' \
    --exclude 'reports/' \
    --exclude 'test-*.sh' \
    ./ ubuntu@130.110.251.193:/opt/palantir-monitor/
```

### Step 4: SSH Back and Deploy

**SSH back to the VM:**
```bash
ssh -i ~/vault/A0_keys/ssh/id_rsa ubuntu@130.110.251.193
cd /opt/palantir-monitor
```

**Build and start containers:**
```bash
# Make scripts executable
chmod +x scripts/*.sh entrypoint.sh

# Stop any existing containers
docker-compose down 2>/dev/null || true

# Build the image
docker-compose build

# Start the cron scheduler (runs daily at 7 AM UTC)
docker-compose up -d palantir-cron

# Check status
docker-compose ps
```

### Step 5: Test Email Sending

**Run a manual test:**
```bash
docker-compose run --rm palantir-monitor
```

**Look for this success message:**
```
[OK] Email sent via Mailu SMTPS with attachments (MD + JSON)
```

**Check your email at me@diegonmarcos.com** for the health report!

---

## Verification

### Check Cron Status
```bash
docker logs palantir-cron
```

### View Generated Reports
```bash
docker volume ls | grep palantir
docker run --rm -v palantir-monitor_palantir-reports:/reports alpine ls -lah /reports
```

### View Latest Report
```bash
docker run --rm -v palantir-monitor_palantir-reports:/reports alpine cat /reports/$(docker run --rm -v palantir-monitor_palantir-reports:/reports alpine ls -t /reports | grep .md | head -1)
```

---

## Troubleshooting

### If Email Fails

1. **Check SMTP Password:**
   ```bash
   cat .env
   # Should show: SMTP_PASS=ogeid2B@
   ```

2. **Test SMTP Connectivity:**
   ```bash
   timeout 5 bash -c 'cat < /dev/null > /dev/tcp/130.110.251.193/465' && echo "Port 465 OK" || echo "Port 465 blocked"
   ```

3. **View Container Logs:**
   ```bash
   docker logs palantir-monitor
   ```

### If Container Won't Start

1. **Check Docker status:**
   ```bash
   docker ps
   systemctl status docker
   ```

2. **Rebuild image:**
   ```bash
   docker-compose build --no-cache
   docker-compose up -d palantir-cron
   ```

3. **Check resource usage:**
   ```bash
   free -h
   df -h
   ```

---

## Schedule Information

- **Cron Schedule:** Daily at 7:00 AM UTC (configured in palantir-cron service)
- **Container:** `palantir-cron` (always running, spawns `palantir-monitor` daily)
- **Resource Limits:** 64MB RAM, 0.25 CPU cores
- **Email To:** me@diegonmarcos.com
- **Email From:** no-reply@diegonmarcos.com

---

## Files Deployed

```
/opt/palantir-monitor/
├── .env                    ← SMTP password (DO NOT COMMIT)
├── .gitignore              ← Protects .env
├── Dockerfile              ← Container image
├── docker-compose.yml      ← Service definition
├── entrypoint.sh           ← SSH key setup
├── config/
│   └── endpoints.conf      ← VM IPs and domains
└── scripts/
    ├── run-checks.sh       ← Main orchestrator
    ├── check-external.sh   ← HTTP/port/DNS checks
    ├── check-cloud.sh      ← VM health via SSH
    ├── check-docker.sh     ← Container counts
    ├── check-ports.sh      ← Port analysis
    ├── check-ips.sh        ← IP inventory
    ├── check-security.sh   ← SSL/headers
    └── check-sauron.sh     ← Malware reports
```

---

## What Was Fixed

### Problem
Palantir-monitor was failing to send daily health reports because:
1. ❌ No SMTP password configured → primary email method (port 465) was skipped
2. ❌ HTTP SMTP proxy (port 8080) blocked by Oracle Cloud infrastructure

### Solution
✅ Added SMTP password (`ogeid2B@`) to `.env` file
✅ Enabled direct SMTP authentication to Mailu server on port 465 (SMTPS)
✅ Port 465 is confirmed working and not blocked by Oracle

### Result
- Email reports will now send via Mailu SMTPS with both MD and JSON attachments
- Daily reports arrive at me@diegonmarcos.com at 7 AM UTC
- Fallback to ntfy notifications if SMTP fails
