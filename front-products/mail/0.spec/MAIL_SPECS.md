# Mail Server Specification

> **Consolidated Mail Documentation**
> **Last Updated:** 2026-01-07
> **VM:** oci-f-micro_1 (130.110.251.193)
> **Status:** WORKING (Inbound + Outbound)

---

## Table of Contents

1. [Current Status](#1-current-status)
2. [Architecture](#2-architecture)
3. [Infrastructure](#3-infrastructure)
4. [IP Change Management](#4-ip-change-management)
5. [Services & Endpoints](#5-services--endpoints)
6. [Configuration](#6-configuration)
7. [OCI Email Delivery Relay](#7-oci-email-delivery-relay)
8. [Cloudflare Integration](#8-cloudflare-integration)
9. [DNS Records](#9-dns-records)
10. [Credentials](#10-credentials)
11. [Client Configuration](#11-client-configuration)
12. [Maintenance & Commands](#12-maintenance--commands)
13. [Troubleshooting](#13-troubleshooting)
14. [Historical Notes](#14-historical-notes)

---

## 1. Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| **Mailu Mail Server** | DEPLOYED | 8 containers, latest version |
| **Outbound Email** | WORKING | Via OCI Email Delivery Relay |
| **Inbound Email** | WORKING | Cloudflare Worker → SMTP proxy (port 8080) → Mailu |
| **Webmail (Roundcube)** | WORKING | https://mail.diegonmarcos.com/webmail |
| **Admin Panel** | WORKING | https://mail.diegonmarcos.com/admin |
| **IMAP (993)** | WORKING | SSL/TLS |
| **SMTP (465)** | WORKING | SMTPS (implicit TLS) |
| **Let's Encrypt TLS** | WORKING | Auto-renewal |
| **DKIM Signing** | CONFIGURED | DNS record in Cloudflare |

### Pending Issues

- [x] ~~FIX INBOUND EMAIL~~ - Port 8080 now open, Worker delivers to Mailu
- [x] ~~Fix Worker/Proxy header mismatch~~ - Working
- [x] ~~Fix Worker/Proxy body format mismatch~~ - Working
- [x] Set `BACKUP_EMAIL` to `diegonmarcos@live.com` as fallback

---

## 2. Architecture

### Inbound Mail Flow (WORKING)

```
Internet → Cloudflare MX (port 25) → Email Worker → SMTP Proxy (8080) → Mailu
                                          │
                                          └── Fallback: diegonmarcos@live.com
```

### Outbound Mail Flow (WORKING)

```
Client → Mailu (port 465/SMTPS) → Postfix → OCI Email Delivery Relay → Internet
                                            [smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
```

### Full Architecture Diagram

```
                              ┌─────────────────────────────────────────────────────┐
                              │                     INTERNET                        │
                              └───────────────────────┬─────────────────────────────┘
                                                      │
                    ┌─────────────────────────────────┼─────────────────────────────────┐
                    │                                 │                                 │
                    ▼                                 ▼                                 ▼
         ┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
         │   Cloudflare     │            │   Cloudflare     │            │   Mail Clients   │
         │   MX Records     │            │   DNS (A record) │            │  (Thunderbird)   │
         │   (port 25)      │            │ mail.diegonmarcos│            └────────┬─────────┘
         └────────┬─────────┘            └────────┬─────────┘                     │
                  │                               │                               │
                  ▼                               │                               │
         ┌──────────────────┐                     │                               │
         │ Cloudflare       │                     │                               │
         │ Email Routing    │                     │                               │
         └────────┬─────────┘                     │                               │
                  │                               │                               │
                  ▼                               │                               │
         ┌──────────────────┐                     │                               │
         │ email-forwarder  │                     │                               │
         │ Worker (WORKING) │                     │                               │
         └────────┬─────────┘                     │                               │
                  │ Port 8080 → Mailu             │                               │
                  ▼                               ▼                               │
         ┌────────────────────────────────────────────────────────────────────────┤
         │                    GCP Micro 1 (35.226.147.64)                         │
         │                    ┌──────────────────────────────┐                    │
         │                    │  Nginx Proxy Manager (NPM)   │◄───────────────────┤
         │                    │  - TLS Termination           │     HTTPS (443)    │
         │                    │  - mail.diegonmarcos.com     │                    │
         │                    └──────────────┬───────────────┘                    │
         └────────────────────────────────────┼───────────────────────────────────┘
                                              │ HTTP Proxy
                                              ▼
         ┌────────────────────────────────────────────────────────────────────────┐
         │                    OCI Micro 1 (130.110.251.193)                       │
         │                                                                        │
         │    ┌────────────────────────────────────────────────────────────┐      │
         │    │                    MAILU STACK                             │      │
         │    │                                                            │      │
         │    │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │      │
         │    │  │ mailu-front │  │ mailu-admin │  │mailu-webmail│        │      │
         │    │  │   (nginx)   │  │   (Flask)   │  │ (Roundcube) │        │      │
         │    │  │ 80,443,25,  │  └─────────────┘  └─────────────┘        │      │
         │    │  │ 465,587,993 │                                          │      │
         │    │  └──────┬──────┘                                          │      │
         │    │         │                                                 │      │
         │    │  ┌──────┴──────┐  ┌─────────────┐  ┌─────────────┐        │      │
         │    │  │ mailu-smtp  │  │ mailu-imap  │  │mailu-antispam│       │      │
         │    │  │  (Postfix)  │  │  (Dovecot)  │  │  (rspamd)   │        │      │
         │    │  └──────┬──────┘  └─────────────┘  └─────────────┘        │      │
         │    │         │                                                 │      │
         │    │  ┌──────┴──────┐  ┌─────────────┐                         │      │
         │    │  │ mailu-redis │  │mailu-resolver│                        │      │
         │    │  │  (cache)    │  │  (unbound)  │                         │      │
         │    │  └─────────────┘  └─────────────┘                         │      │
         │    │                                                            │      │
         │    └────────────────────────────┬───────────────────────────────┘      │
         │                                 │                                      │
         └─────────────────────────────────┼──────────────────────────────────────┘
                                           │ Port 587/STARTTLS
                                           ▼
         ┌────────────────────────────────────────────────────────────────────────┐
         │                    OCI Email Delivery Service                          │
         │              smtp.email.eu-marseille-1.oci.oraclecloud.com             │
         │                         (Outbound Relay)                               │
         └────────────────────────────────┬───────────────────────────────────────┘
                                          │ Port 25
                                          ▼
                              ┌──────────────────────────────┐
                              │   Recipient Mail Servers     │
                              │   (Gmail, Outlook, etc.)     │
                              └──────────────────────────────┘
```

---

## 3. Infrastructure

### Virtual Machines

| VM | IP | Provider | Role |
|----|-----|----------|------|
| **oci-f-micro_1** | 130.110.251.193 | Oracle Cloud | Mailu mail server host |
| **gcp-f-micro_1** | 35.226.147.64 | Google Cloud | NPM reverse proxy (TLS termination) |

### Docker Containers (Mailu Stack)

```
CONTAINER           IMAGE                              STATUS          PORTS
mailu-front-1       mailu/nginx:latest                 Up (healthy)    80,443,25,465,587,993
mailu-admin-1       mailu/admin:latest                 Up (healthy)    -
mailu-smtp-1        mailu/postfix:latest               Up (healthy)    -
mailu-imap-1        mailu/dovecot:latest               Up (healthy)    -
mailu-antispam-1    mailu/rspamd:latest                Up (healthy)    -
mailu-webmail-1     mailu/roundcube:latest             Up (healthy)    -
mailu-redis-1       redis:alpine                       Up              -
mailu-resolver-1    mailu/unbound:latest               Up (healthy)    -
```

### Docker Network

| VM | Network | Subnet |
|----|---------|--------|
| oci-f-micro_1 | mail_network | 172.20.0.0/24 |

---

## 4. IP Change Management

### Current IPs (Source of Truth)

| Component | IP Address | Purpose |
|-----------|------------|---------|
| **Mailu Server (oci-f-micro_1)** | `130.110.251.193` | Mail server hosting |
| **NPM Proxy (gcp-f-micro_1)** | `35.226.147.64` | Reverse proxy for webmail |

### When GCloud Proxy IP Changes - UPDATE THESE:

1. **Cloudflare DNS** (mail.diegonmarcos.com A record)
   - Location: Cloudflare Dashboard > DNS
   - Update: A record for `mail.diegonmarcos.com` to new GCloud IP

2. **Mailu PROXY_AUTH_WHITELIST** (on oci-f-micro_1)
   - Location: `/opt/mailu/mailu.env`
   - Update: `PROXY_AUTH_WHITELIST=<new_gcloud_ip>`
   - Restart: `cd /opt/mailu && sudo docker-compose restart`

3. **WireGuard Peer Endpoint** (on oci-f-micro_1)
   - Location: `/etc/wireguard/wg0.conf`
   - Update: `Endpoint = <new_gcloud_ip>:51820`
   - Restart: `sudo wg-quick down wg0 && sudo wg-quick up wg0`

### When Oracle Mail Server IP Changes - UPDATE THESE:

1. **Cloudflare DNS** (smtp.diegonmarcos.com A record)
   - Update: A record for `smtp.diegonmarcos.com` to new Oracle IP

2. **NPM Proxy Host** (on gcp-f-micro_1)
   - Location: NPM Admin UI (http://35.226.147.64:81)
   - Update: Forward Host for mail.diegonmarcos.com

3. **Cloudflare Email Worker** (if using SMTP proxy)
   - Location: Cloudflare Dashboard > Workers
   - Update: `SMTP_PROXY_URL` environment variable

### DO NOT TOUCH (Docker manages automatically):

- iptables NAT rules
- Container IP addresses
- Docker network configurations

### Recovery Commands

```bash
# If iptables corrupted, restart Docker to regenerate:
sudo systemctl restart docker

# Check Mailu container status:
cd /opt/mailu && sudo docker-compose ps

# View Mailu logs:
cd /opt/mailu && sudo docker-compose logs -f mailu-front-1
```

---

## 5. Services & Endpoints

| Service | URL/Port | Status |
|---------|----------|--------|
| Mailu Admin | https://mail.diegonmarcos.com/admin | OK |
| Roundcube Webmail | https://mail.diegonmarcos.com/webmail | OK |
| IMAP (read mail) | mail.diegonmarcos.com:993 | OK |
| SMTP (send mail) | mail.diegonmarcos.com:465 (SMTPS) | OK |
| SMTP Submission | mail.diegonmarcos.com:587 (STARTTLS) | Issues |
| **Inbound Email** | Cloudflare → Worker → Mailu | WORKING |

---

## 6. Configuration

### Configuration Files (on oci-f-micro_1)

| File | Purpose |
|------|---------|
| `/opt/mailu/mailu.env` | Main Mailu configuration |
| `/opt/mailu/docker-compose.yml` | Docker Compose definition |
| `/opt/mailu/dkim/diegonmarcos.com.dkim.key` | DKIM private key |
| `/opt/mailu/dkim/diegonmarcos.com.dkim.pub` | DKIM public key |

### Key Environment Variables (mailu.env)

```bash
# Domain
DOMAIN=diegonmarcos.com
HOSTNAMES=mail.diegonmarcos.com

# OCI Email Delivery Relay
RELAYHOST=[smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
RELAYUSER=ocid1.user.oc1..aaaaaaaaadh3p7atydr4ga3yvr3noohaar4f5h62d7stidvzkzgmilyt4enq@ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq.lm.com
RELAYPASSWORD=.<zLnkRzJBv$2FiJaf-G

# Proxy whitelist (GCloud NPM IP)
PROXY_AUTH_WHITELIST=35.226.147.64
```

**CRITICAL:** Square brackets around RELAYHOST hostname and `:587` port are REQUIRED for Postfix.

---

## 7. OCI Email Delivery Relay

### Why OCI Relay?

Oracle Cloud blocks outbound port 25 to prevent spam. All outbound mail must go through OCI Email Delivery service via port 587.

### OCI Email Delivery Settings

| Setting | Value |
|---------|-------|
| SMTP Endpoint | `smtp.email.eu-marseille-1.oci.oraclecloud.com` |
| Port | `587` (STARTTLS) |
| Region | eu-marseille-1 |
| Protocol | SMTP with STARTTLS |

### SMTP Credentials

Created via OCI Console: Identity & Security > Users > SMTP Credentials

| Setting | Value |
|---------|-------|
| Username | `ocid1.user.oc1..aaaaaaaaadh3p7atydr4ga3yvr3noohaar4f5h62d7stidvzkzgmilyt4enq@ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq.lm.com` |
| Password | `.<zLnkRzJBv$2FiJaf-G` |

### OCI Setup Commands

```bash
# List approved senders
oci email sender list --compartment-id <compartment-id>

# Create approved sender
oci email sender create \
  --compartment-id <compartment-id> \
  --email-address "me@diegonmarcos.com"

# List SMTP credentials
oci iam smtp-credential list --user-id <user-id>
```

---

## 8. Cloudflare Integration

### Email Routing

Cloudflare Email Routing receives all inbound mail on port 25 via MX records.

### Email Worker (email-forwarder)

| Setting | Value | Status |
|---------|-------|--------|
| Worker Name | `email-forwarder` | WORKING |
| SMTP_PROXY_URL | `http://smtp.diegonmarcos.com:8080/` | WORKING |
| SMTP_PROXY_KEY | `stalwart-proxy-key-2025` | - |
| BACKUP_EMAIL | `diegonmarcos@live.com` | Fallback configured |
| Route | `me@diegonmarcos.com` → Worker → Mailu | WORKING |

---

## 9. DNS Records

### Current DNS Configuration (Cloudflare)

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| MX | @ | route1.mx.cloudflare.net (priority 10) | - |
| MX | @ | route2.mx.cloudflare.net (priority 20) | - |
| MX | @ | route3.mx.cloudflare.net (priority 30) | - |
| A | mail | 35.226.147.64 (GCP NPM) | OFF |
| A | smtp | 130.110.251.193 (OCI Mailu) | OFF |
| TXT | @ | `v=spf1 include:_spf.mx.cloudflare.net include:rp.oracleemaildelivery.com ~all` | - |
| TXT | _dmarc | `v=DMARC1; p=none; rua=mailto:admin@diegonmarcos.com` | - |
| TXT | dkim._domainkey | `v=DKIM1; k=rsa; p=MIIBIjAN...` | - |

---

## 10. Credentials

### Mailu Admin

| Field | Value |
|-------|-------|
| URL | https://mail.diegonmarcos.com/admin |
| Username | admin@diegonmarcos.com |
| Password | 8HkSfq6mCW |

### Email Account

| Field | Value |
|-------|-------|
| Email | me@diegonmarcos.com |
| Password | ogeid1A! |

### OCI SMTP Relay

| Field | Value |
|-------|-------|
| Host | smtp.email.eu-marseille-1.oci.oraclecloud.com:587 |
| Username | (see RELAYUSER in Section 7) |
| Password | `.<zLnkRzJBv$2FiJaf-G` |

---

## 11. Client Configuration

### Thunderbird / Desktop Clients

| Setting | Value |
|---------|-------|
| **IMAP Server** | mail.diegonmarcos.com |
| **IMAP Port** | 993 |
| **IMAP Security** | SSL/TLS |
| **SMTP Server** | mail.diegonmarcos.com |
| **SMTP Port** | 465 |
| **SMTP Security** | SSL/TLS (SMTPS) |
| **Username** | me@diegonmarcos.com |
| **Password** | ogeid1A! |

### Mobile (K-9 Mail / FairEmail)

Same settings as desktop clients.

---

## 12. Maintenance & Commands

### SSH Access

```bash
# SSH to mail server
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193
```

### Container Management

```bash
# Navigate to Mailu directory
cd /opt/mailu

# Check container status
sudo docker-compose ps

# View all logs
sudo docker-compose logs -f

# View specific container logs
sudo docker-compose logs -f mailu-front-1
sudo docker-compose logs -f mailu-smtp-1

# Restart all containers
sudo docker-compose restart

# Restart specific container
sudo docker-compose restart mailu-smtp-1
```

### Port Testing

```bash
# Test IMAP (from local machine)
openssl s_client -connect mail.diegonmarcos.com:993

# Test SMTP submission
openssl s_client -connect mail.diegonmarcos.com:465

# Test with nc
nc -zv mail.diegonmarcos.com 993
nc -zv mail.diegonmarcos.com 465
```

### TLS Certificate

```bash
# Verify certificate
openssl s_client -connect mail.diegonmarcos.com:993 -servername mail.diegonmarcos.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

---

## 13. Troubleshooting

### Emails Going to Spam

- Verify DKIM DNS record is correct
- Check SPF record includes all sending sources
- Review DMARC policy

### Connection Timeouts to Port 25

- Expected: OCI blocks outbound port 25
- Must use port 587 via OCI Email Delivery relay

### Port 587 TLS Issues

- Mailu port 587 has STARTTLS issues
- Use port 465 (implicit TLS/SMTPS) instead

### Relay Not Working

```bash
# Check relay configuration in Postfix
docker exec mailu-smtp-1 cat /etc/postfix/main.cf | grep relay

# Check logs for delivery attempts
docker logs mailu-smtp-1 | grep -E "(relay|delivery|smtp.email)"
```

### Inbound Email Not Working

- Check port 8080 connectivity: `nc -zv 130.110.251.193 8080`
- Check Worker logs in Cloudflare Dashboard
- Fallback: Emails will be forwarded to `diegonmarcos@live.com` if primary fails

### RAM Issues

```bash
# Check memory usage
free -h
docker stats --no-stream

# VM has 1GB total, Mailu uses ~512MB-1GB
```

---

## 14. Historical Notes

### Migration from Stalwart (2025-12-08)

Stalwart Mail Server was removed due to complex relay configuration (split between TOML and database). Mailu was chosen for:

- Simple env-based relay configuration
- Built-in webmail (Roundcube)
- Admin UI for user management
- Lightweight configuration without antivirus

### Key Learnings

1. **Stalwart complexity**: Relay config split between TOML and database made troubleshooting difficult
2. **Postfix RELAYHOST format**: Square brackets `[hostname]:port` are REQUIRED
3. **OCI blocks port 25 outbound**: All outbound mail must go through OCI Email Delivery
4. **Port 587 TLS issues**: Using port 465 (SMTPS) works reliably
5. **Spam folder delivery**: Emails without DKIM go to spam

### Previous Implementations (Not Active)

- **Stalwart Mail Server** - Removed
- **Snappymail Webmail** - Removed (replaced by Roundcube in Mailu)
- **Google Hybrid Approach** - Not implemented (using Cloudflare + OCI instead)

---

## Quick Reference

```bash
# SSH to server
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193

# Mailu Admin
https://mail.diegonmarcos.com/admin (admin@diegonmarcos.com / 8HkSfq6mCW)

# Roundcube Webmail
https://mail.diegonmarcos.com/webmail (me@diegonmarcos.com / ogeid1A!)

# Check services
cd /opt/mailu && sudo docker-compose ps

# View logs
cd /opt/mailu && sudo docker-compose logs -f
```

---

**Source Files Consolidated:**
- `mail-app/STATUS.md`
- `mail-app/README.md`
- `mail-app/IMPLEMENTATION_PLAN.md`
- `mail-app/OCI-RELAY.md`
- `dkim/README.md`
- `0.spec/archive/.../2025-12-08_Mail_Configuration_Log.md`
