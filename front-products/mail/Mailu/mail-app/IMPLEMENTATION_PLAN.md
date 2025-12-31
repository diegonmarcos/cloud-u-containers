# Mail Server Implementation Plan (Google Hybrid)

> **FOR CLAUDE SONNET - READ CAREFULLY BEFORE EXECUTING**

---

## CRITICAL WARNINGS

```
DO NOT skip steps or assume anything is already done
DO NOT run commands without verifying the previous step succeeded
DO NOT modify files outside the specified paths
ALWAYS check command output before proceeding
ALWAYS ask user for confirmation before destructive operations
STOP and report if any command fails or unexpected output
```

---

## Architecture Overview

### Google Hybrid Approach

```
INCOMING EMAIL FLOW:
Internet --> Google (MX Priority 10) --> Auto-forward --> Your Mail Server (stores locally)
                                                                    |
                                                              Webmail access

OUTGOING EMAIL FLOW:
Your Webmail --> Your Mail Server --> Google SMTP Relay --> Internet
                                            |
                                    Uses Google's IP reputation
                                    Appears from: me@, help@, news@, etc.
```

### Why This Architecture?
- **Google handles receiving** - No port 25 issues, reliable delivery
- **Google SMTP relay for sending** - Uses Google's reputation, no spam folder issues
- **Your server = webmail + storage** - Full control, access from anywhere
- **Multiple aliases** - Send from me@, help@, news@, etc.

---

## Service Information

| Field | Value | VERIFY THIS |
|-------|-------|-------------|
| **Parent Service** | mail | In cloud_dash.json |
| **Child Services** | mail-app, mail-db | In cloud_dash.json |
| **Target VM** | oci-f-micro_1 | Oracle Free Micro 1 |
| **VM IP** | 130.110.251.193 | Verify with `ssh ubuntu@130.110.251.193` |
| **SSH Command** | `ssh ubuntu@130.110.251.193` | Use THIS exact command |
| **Docker Image** | docker-mailserver/docker-mailserver:latest | Do NOT change |
| **Status** | DEV --> ON (after completion) | Update only when ALL tests pass |

### Architecture (MEMORIZE THIS)

```
oci-f-micro_1 (130.110.251.193)       <-- THIS VM ONLY
├── npm-oracle-web (port 81)          <-- Already exists
└── mail_network (172.20.0.0/24)      <-- Create if not exists
    └── mail-app                      <-- Main container
        ├── Port 587 --> Submission (for sending)
        ├── Port 993 --> IMAPS (for webmail)
        └── Port 25  --> SMTP (receives forwarded from Google)
```

### Resource Limits

| Resource | Value | DO NOT EXCEED |
|----------|-------|---------------|
| RAM | 1 GB total VM | mail-app max 512MB-1GB |
| Storage | 47 GB | Monitor with `df -h` |

> **WARNING:** This VM only has 1 GB RAM and runs npm-oracle-web. Mail uses 512MB-1GB. VM will be AT CAPACITY.

---

## Files Location

All files are at:
```
/home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-f-micro_1/2.app/mail-app/
├── .env.example              # Template for Google SMTP credentials
├── IMPLEMENTATION_PLAN.md    # This file
├── docker-compose.yml        # Container config (already has Google relay)
└── config/
    └── postfix-virtual.cf    # Email aliases
```

### Credentials Location
```
/home/diego/Documents/Git/LOCAL_KEYS/local_keys/secrets/
└── mail-relay.env            # Create this with Google App Password
```

---

## Pre-Implementation Checklist

**COMPLETE ALL CHECKS BEFORE STARTING:**

```bash
# CHECK 1: Verify you can SSH to the correct VM
ssh ubuntu@130.110.251.193 "hostname && whoami"
# EXPECTED OUTPUT: Shows hostname and "ubuntu"
# IF FAILS: Stop and report to user

# CHECK 2: Verify Docker is installed
ssh ubuntu@130.110.251.193 "docker --version"
# EXPECTED OUTPUT: Docker version 2X.X.X or higher
# IF FAILS: Install Docker first (ask user)

# CHECK 3: Verify docker compose is available
ssh ubuntu@130.110.251.193 "docker compose version"
# EXPECTED OUTPUT: Docker Compose version v2.X.X
# IF FAILS: Install docker-compose-plugin

# CHECK 4: Check current containers (know what exists)
ssh ubuntu@130.110.251.193 "docker ps -a"
# NOTE: Should see npm-oracle-web running. Do NOT stop it without asking

# CHECK 5: Check available disk space
ssh ubuntu@130.110.251.193 "df -h /"
# EXPECTED: At least 10GB free
# IF LOW: Report to user before continuing

# CHECK 6: Check RAM usage
ssh ubuntu@130.110.251.193 "free -h"
# NOTE: VM has 1GB total. NPM uses ~128-256MB. Mail needs ~512MB-1GB.
```

---

## Phase 1: Google Configuration (USER MUST DO)

### Step 1.1: Create Google App Password

**TELL THE USER:**

1. Go to https://myaccount.google.com/apppasswords
2. Sign in with the Google Workspace account (or Gmail)
3. Select app: "Mail"
4. Select device: "Other" --> name it "mail-server"
5. Click "Generate"
6. **SAVE the 16-character password** (shown only once!)

### Step 1.2: Create Credentials File

**TELL THE USER to create this file:**

```bash
# Create the credentials file
cat > /home/diego/Documents/Git/LOCAL_KEYS/local_keys/secrets/mail-relay.env << 'EOF'
RELAY_USER=your-email@diegonmarcos.com
RELAY_PASSWORD=xxxx-xxxx-xxxx-xxxx
EOF

# Secure it
chmod 600 /home/diego/Documents/Git/LOCAL_KEYS/local_keys/secrets/mail-relay.env
```

### Step 1.3: Configure Google Workspace SMTP Relay (if using Workspace)

**TELL THE USER:**

1. Go to Google Admin Console --> Apps --> Gmail --> Routing
2. Add "SMTP relay service"
3. Settings:
   - Allowed senders: "Only addresses in my domains"
   - Authentication: "Require SMTP authentication"
   - Encryption: "Require TLS encryption"
4. Save

### Step 1.4: Configure Google Forwarding

**TELL THE USER:**

Option A - Per-user forwarding (simpler):
1. Log into Gmail with the account
2. Settings --> See all settings --> Forwarding and POP/IMAP
3. Add forwarding address: admin@mail.diegonmarcos.com
4. Keep copy in Gmail: YES (for backup)

Option B - Admin routing (all users):
1. Google Admin --> Apps --> Gmail --> Routing
2. Add routing rule for all incoming mail
3. Forward to: admin@mail.diegonmarcos.com

**CHECKPOINT 1: Do NOT proceed unless:**
- [ ] User has Google App Password saved
- [ ] User created mail-relay.env file
- [ ] User confirmed Google forwarding is set up

---

## Phase 2: DNS Configuration

### Step 2.1: Required DNS Records

**TELL THE USER to add/verify these records:**

| Type | Name | Value | TTL | Notes |
|------|------|-------|-----|-------|
| MX | @ (root) | aspmx.l.google.com | 3600 | Priority 1 - KEEP THIS |
| MX | @ (root) | alt1.aspmx.l.google.com | 3600 | Priority 5 - KEEP THIS |
| A | mail | 130.110.251.193 | 3600 | Your mail server (Oracle) |
| TXT | @ (root) | `v=spf1 include:_spf.google.com ip4:130.110.251.193 ~all` | 3600 | SPF - includes both |
| TXT | _dmarc | `v=DMARC1; p=none; rua=mailto:admin@diegonmarcos.com` | 3600 | DMARC |

**IMPORTANT:** Keep Google as primary MX! Your server just receives forwarded mail.

### Step 2.2: Verify DNS

```bash
# Run these from local machine

# Check MX still points to Google
dig MX diegonmarcos.com +short
# EXPECTED: Shows Google MX servers (aspmx.l.google.com, etc.)

# Check A record for your mail server
dig A mail.diegonmarcos.com +short
# EXPECTED: 130.110.251.193

# Check SPF includes both Google and your IP
dig TXT diegonmarcos.com +short | grep spf
# EXPECTED: "v=spf1 include:_spf.google.com ip4:130.110.251.193 ~all"
```

**CHECKPOINT 2: Do NOT proceed unless:**
- [ ] MX records point to Google (primary)
- [ ] A record for mail.diegonmarcos.com = 130.110.251.193
- [ ] SPF includes both Google and your IP

---

## Phase 3: VM Preparation

### Step 3.1: Create Docker Network

```bash
# SSH into VM
ssh ubuntu@130.110.251.193

# Check if network exists
docker network ls | grep mail_network

# IF NOT EXISTS: Create it
docker network create --driver bridge --subnet 172.20.0.0/24 mail_network

# VERIFY
docker network ls | grep mail_network
# EXPECTED: Shows mail_network with bridge driver
```

### Step 3.2: Verify Firewall Rules (OCI Security List)

**TELL THE USER to verify in OCI Console:**

1. Go to OCI Console --> Networking --> Virtual Cloud Networks
2. Find the VCN for oci-f-micro_1
3. Check Security Lists --> Ingress Rules
4. Ensure these ports are open:
   - TCP 25 (SMTP)
   - TCP 587 (Submission)
   - TCP 993 (IMAPS)

**OR use OCI CLI:**
```bash
# List security rules (run from local with OCI CLI configured)
oci network security-list list --compartment-id <your-compartment-id> --query 'data[*].{"name":"display-name","rules":"ingress-security-rules"}'
```

**CHECKPOINT 3: Do NOT proceed unless:**
- [ ] mail_network exists
- [ ] Firewall/Security List allows ports 25, 587, 993

---

## Phase 4: Directory Setup

### Step 4.1: Create Directories on VM

```bash
# SSH into VM
ssh ubuntu@130.110.251.193

# Create directory structure
sudo mkdir -p /opt/mail/config
sudo mkdir -p /opt/mail/letsencrypt

# Set ownership
sudo chown -R $USER:$USER /opt/mail

# VERIFY
ls -la /opt/mail/
# EXPECTED: Shows config/ and letsencrypt/
```

### Step 4.2: Copy Files to VM

```bash
# From LOCAL machine, copy all files:

# docker-compose.yml
scp /home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-f-micro_1/2.app/mail-app/docker-compose.yml ubuntu@130.110.251.193:/opt/mail/docker-compose.yml

# .env file (from LOCAL_KEYS)
scp /home/diego/Documents/Git/LOCAL_KEYS/local_keys/secrets/mail-relay.env ubuntu@130.110.251.193:/opt/mail/.env

# config directory
scp -r /home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-f-micro_1/2.app/mail-app/config ubuntu@130.110.251.193:/opt/mail/

# VERIFY files were copied
ssh ubuntu@130.110.251.193 "ls -la /opt/mail/"
# EXPECTED: docker-compose.yml, .env, config/

ssh ubuntu@130.110.251.193 "cat /opt/mail/.env"
# EXPECTED: Shows RELAY_USER and RELAY_PASSWORD (DO NOT LOG THESE)
```

**CHECKPOINT 4: Do NOT proceed unless:**
- [ ] /opt/mail directory exists
- [ ] docker-compose.yml copied
- [ ] .env file copied with credentials
- [ ] config/ directory copied

---

## Phase 5: SSL/TLS Certificates

### Step 5.1: Install Certbot

```bash
# SSH into VM
ssh ubuntu@130.110.251.193

# Check if certbot exists
which certbot

# IF NOT FOUND (Ubuntu):
sudo apt update && sudo apt install -y certbot

# VERIFY
certbot --version
```

### Step 5.2: Generate Certificate

```bash
# IMPORTANT: Stop any service using port 80 first
sudo docker stop npm-oracle-web 2>/dev/null || true

# Generate certificate
sudo certbot certonly --standalone -d mail.diegonmarcos.com

# EXPECTED: "Congratulations! Your certificate and chain have been saved"

# Restart npm-oracle-web
sudo docker start npm-oracle-web 2>/dev/null || true

# VERIFY certificate exists
sudo ls -la /etc/letsencrypt/live/mail.diegonmarcos.com/
# EXPECTED: fullchain.pem, privkey.pem
```

### Step 5.3: Link Certificates

```bash
# Create symlink
sudo ln -sf /etc/letsencrypt /opt/mail/letsencrypt

# VERIFY
ls -la /opt/mail/letsencrypt/live/mail.diegonmarcos.com/
# EXPECTED: Shows certificate files
```

**CHECKPOINT 5: Do NOT proceed unless:**
- [ ] Certificate generated for mail.diegonmarcos.com
- [ ] Symlink at /opt/mail/letsencrypt works

---

## Phase 6: Deploy Mail Server

### Step 6.1: Start Container

```bash
# SSH into VM
ssh ubuntu@130.110.251.193

# Navigate to mail directory
cd /opt/mail

# Pull latest image
docker pull docker-mailserver/docker-mailserver:latest

# Start container
docker compose up -d

# WAIT 60 seconds for initialization
sleep 60

# Check container is running
docker ps | grep mail-app
# EXPECTED: mail-app with status "Up"

# Check logs for errors
docker logs mail-app 2>&1 | tail -50
# LOOK FOR: Any ERROR or FATAL messages
# IF ERRORS: Stop and report to user
```

### Step 6.2: Create Email Account

```bash
# Create admin account
docker exec -it mail-app setup email add admin@diegonmarcos.com
# Enter password when prompted

# VERIFY account created
docker exec -it mail-app setup email list
# EXPECTED: admin@diegonmarcos.com
```

### Step 6.3: Add Email Aliases

```bash
# Add all aliases (they all go to admin mailbox)
docker exec -it mail-app setup alias add me@diegonmarcos.com admin@diegonmarcos.com
docker exec -it mail-app setup alias add help@diegonmarcos.com admin@diegonmarcos.com
docker exec -it mail-app setup alias add news@diegonmarcos.com admin@diegonmarcos.com
docker exec -it mail-app setup alias add info@diegonmarcos.com admin@diegonmarcos.com
docker exec -it mail-app setup alias add contact@diegonmarcos.com admin@diegonmarcos.com
docker exec -it mail-app setup alias add support@diegonmarcos.com admin@diegonmarcos.com

# VERIFY aliases
docker exec -it mail-app setup alias list
# EXPECTED: Shows all aliases pointing to admin@
```

**CHECKPOINT 6: Do NOT proceed unless:**
- [ ] Container running
- [ ] No errors in logs
- [ ] admin@diegonmarcos.com account created
- [ ] All aliases configured

---

## Phase 7: Testing

### Step 7.1: Test Ports

```bash
# From LOCAL machine

# Test port 587 (submission)
openssl s_client -connect mail.diegonmarcos.com:587 -starttls smtp
# EXPECTED: Certificate info, no errors

# Test port 993 (IMAPS)
openssl s_client -connect mail.diegonmarcos.com:993
# EXPECTED: Certificate info, no errors
```

### Step 7.2: Test Google Relay (Sending)

```bash
# SSH into VM
ssh ubuntu@130.110.251.193

# Send test email via relay
docker exec -it mail-app swaks \
    --to your-personal-gmail@gmail.com \
    --from admin@diegonmarcos.com \
    --server localhost \
    --port 587 \
    --auth-user admin@diegonmarcos.com \
    --auth-password "your-admin-password" \
    --tls

# EXPECTED: "250 2.0.0 Ok: queued"
# CHECK: Email arrives in your Gmail inbox (not spam!)
```

### Step 7.3: Test Receiving (Google Forward)

**TELL THE USER:**
1. Send an email FROM your personal Gmail TO admin@diegonmarcos.com
2. Google should receive it and forward to your mail server
3. Check the mail arrived:

```bash
# SSH into VM
ssh ubuntu@130.110.251.193

# Check mailbox
docker exec -it mail-app ls -la /var/mail/diegonmarcos.com/admin/
# EXPECTED: Shows new/ cur/ tmp/ with mail files
```

### Step 7.4: Test Sending from Alias

```bash
# Send from an alias
docker exec -it mail-app swaks \
    --to your-personal-gmail@gmail.com \
    --from help@diegonmarcos.com \
    --server localhost \
    --port 587 \
    --auth-user admin@diegonmarcos.com \
    --auth-password "your-admin-password" \
    --tls

# CHECK: Email arrives FROM help@diegonmarcos.com
```

**CHECKPOINT 7: Do NOT proceed unless:**
- [ ] Ports 587, 993 accessible
- [ ] Sending via Google relay works
- [ ] Receiving forwarded mail works
- [ ] Sending from aliases works

---

## Phase 8: Webmail Client Setup (Optional)

### Option A: Roundcube (Web-based)

```bash
# Add to docker-compose.yml or deploy separately
# Connects to mail-app via IMAP/SMTP
```

### Option B: Use any Email Client

Configure with:
- **IMAP Server:** mail.diegonmarcos.com:993 (SSL)
- **SMTP Server:** mail.diegonmarcos.com:587 (STARTTLS)
- **Username:** admin@diegonmarcos.com
- **Password:** (the one you set)

---

## Phase 9: Update Cloud Dashboard

### Step 9.1: Update cloud_dash.json

**FILE:** `/home/diego/Documents/Git/back-System/cloud/0.spec/cloud_dash.json`

Update these services:
```json
"mail": {
  "status": "on"
}
"mail-app": {
  "status": "on"
}
"mail-db": {
  "status": "on"
}
```

### Step 9.2: Update VM spec

**FILE:** `/home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-f-micro_1/1.os/oci-f-micro_1.md`

Update services table to show mail as ON.

---

## Troubleshooting

### Google Relay Not Working
```bash
# Check relay configuration
docker exec mail-app cat /etc/postfix/main.cf | grep relay

# Check credentials
docker exec mail-app cat /etc/postfix/sasl/sasl_passwd

# Test connection to Google
docker exec mail-app openssl s_client -connect smtp-relay.gmail.com:587 -starttls smtp
```

### Emails Not Being Forwarded from Google
1. Check Google forwarding settings
2. Verify mail.diegonmarcos.com resolves correctly
3. Check spam folder in Google
4. Check mail server logs: `docker logs mail-app | grep -i forward`

### Port 25 Blocked
- Oracle Cloud allows port 25 (unlike GCloud)
- Check OCI Security List for ingress rules
- Receiving on port 25 from Google forward should work

### Certificate Errors
```bash
# Renew certificate
sudo certbot renew
docker compose restart
```

### RAM Issues (VM at capacity)
```bash
# Check memory usage
free -h
docker stats --no-stream

# If mail-app uses too much RAM:
# 1. Disable SpamAssassin (saves ~100MB)
# 2. Reduce log level
```

---

## Commands Reference

```bash
# SSH to VM
ssh ubuntu@130.110.251.193

# Container management
docker ps | grep mail
docker logs mail-app
docker exec -it mail-app bash
docker compose restart

# Email management
docker exec -it mail-app setup email list
docker exec -it mail-app setup email add USER@DOMAIN
docker exec -it mail-app setup alias list
docker exec -it mail-app setup alias add ALIAS@DOMAIN TARGET@DOMAIN

# Queue management
docker exec -it mail-app mailq
docker exec -it mail-app postqueue -f
```

---

## DO NOT DO THESE THINGS

```
DO NOT deploy to gcp-f-micro_1 (wrong VM - that's NPM only)
DO NOT remove Google as primary MX
DO NOT change SMTP relay from Google
DO NOT enable ClamAV (uses too much RAM - VM only has 1GB)
DO NOT skip Google configuration steps
DO NOT mark as "on" until ALL tests pass
```

---

## Summary Checklist

- [ ] Phase 1: Google App Password + Forwarding configured
- [ ] Phase 2: DNS records correct (Google MX + your A record at 130.110.251.193)
- [ ] Phase 3: VM network + OCI firewall ready
- [ ] Phase 4: Files copied to VM
- [ ] Phase 5: SSL certificate generated
- [ ] Phase 6: Container running + accounts created
- [ ] Phase 7: All tests pass (send/receive/aliases)
- [ ] Phase 8: Webmail client configured (optional)
- [ ] Phase 9: Dashboard updated

---

**END OF IMPLEMENTATION PLAN**
