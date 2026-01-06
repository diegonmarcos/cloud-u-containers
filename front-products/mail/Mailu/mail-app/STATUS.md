# Mail App Status

**Status:** INBOUND BROKEN (Outbound OK)
**Date:** 2026-01-06
**VM:** oci-f-micro_1 (130.110.251.193)
**Issue:** Cloudflare Worker cannot reach SMTP proxy (Oracle blocks port 8080)

---

## CRITICAL: IP Dependencies & Change Management

### Current IPs (Source of Truth)
| Component | IP Address | Purpose |
|-----------|------------|---------|
| **Mailu Server (oci-f-micro_1)** | `130.110.251.193` | Mail server hosting |
| **NPM Proxy (gcp-f-micro_1)** | `35.226.147.64` | Reverse proxy for webmail |

### When GCloud Proxy IP Changes - UPDATE THESE:

1. **Cloudflare DNS** (mail.diegonmarcos.com A record)
   - Location: Cloudflare Dashboard > DNS
   - Update: A record for `mail.diegonmarcos.com` to new GCloud IP
   - Command: `ZONE_ID="ff4335cc9c7de42e580d0dff9a0d70eb" curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/<record_id>"`

2. **Mailu PROXY_AUTH_WHITELIST** (on oci-f-micro_1)
   - Location: `/opt/mailu/mailu.env`
   - Update: `PROXY_AUTH_WHITELIST=<new_gcloud_ip>`
   - Restart: `cd /opt/mailu && sudo docker-compose restart`

3. **WireGuard Peer Endpoint** (on oci-f-micro_1)
   - Location: `/etc/wireguard/wg0.conf`
   - Update: `Endpoint = <new_gcloud_ip>:51820`
   - Restart: `sudo wg-quick down wg0 && sudo wg-quick up wg0`

4. **Oracle Security List** (for Radicale port 5232 if needed)
   - Location: OCI Console > Networking > Security Lists
   - Update: Ingress rule source CIDR for port 5232

### When Oracle Mail Server IP Changes - UPDATE THESE:

1. **Cloudflare DNS** (smtp.diegonmarcos.com A record)
   - Update: A record for `smtp.diegonmarcos.com` to new Oracle IP

2. **NPM Proxy Host** (on gcp-f-micro_1)
   - Location: NPM Admin UI (http://35.226.147.64:81)
   - Update: Forward Host for mail.diegonmarcos.com

3. **Cloudflare Email Worker** (if using SMTP proxy)
   - Location: Cloudflare Dashboard > Workers
   - Update: `SMTP_PROXY_URL` environment variable

### DO NOT TOUCH (Docker manages these automatically):
- iptables NAT rules (Docker regenerates on restart)
- Container IP addresses (assigned dynamically by Docker)
- Docker network configurations

### Recovery Commands
```bash
# If iptables are corrupted, restart Docker to regenerate:
sudo systemctl restart docker

# Check Mailu container status:
cd /opt/mailu && sudo docker-compose ps

# View Mailu logs:
cd /opt/mailu && sudo docker-compose logs -f mailu-front-1
```

---

## Deployment Status

| Component | Status | Version |
|-----------|--------|---------|
| ~~Stalwart Mail Server~~ | REMOVED | - |
| ~~Snappymail Webmail~~ | REMOVED | - |
| **Mailu Mail Server** | **DEPLOYED** | latest |
| Cloudflare Email Routing | CONFIGURED | - |
| OCI Security List | CONFIGURED | - |
| OCI Email Delivery Relay | CONFIGURED (in mailu.env) | - |

## Services Running (Mailu)

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

## Endpoints

| Service | URL | Status |
|---------|-----|--------|
| Mailu Admin | https://mail.diegonmarcos.com/admin | OK |
| Roundcube Webmail | https://mail.diegonmarcos.com/webmail | OK |
| IMAP (read mail) | mail.diegonmarcos.com:993 | OK |
| SMTP (send mail) | mail.diegonmarcos.com:465 (SMTPS) | OK |
| **Inbound Email** | Cloudflare → Worker → Mailu | **BROKEN** |

---

## What's Done

- [x] ~~Stalwart removed~~
- [x] Mailu deployed with 8 containers
- [x] Lightweight config (no antivirus, rspamd antispam)
- [x] OCI Email Delivery Relay configured via env vars
- [x] Let's Encrypt TLS certificates
- [x] Domain created (diegonmarcos.com)
- [x] Email account created (me@diegonmarcos.com / ogeid1A!)
- [x] Admin account (admin@diegonmarcos.com / 8HkSfq6mCW)
- [x] Cloudflare Email Routing configured

## Pending

- [x] ~~Test SMTP submission (port 587 TLS issue)~~ - Using port 465 (SMTPS) instead
- [x] ~~Update Thunderbird configuration for Mailu~~ - Updated to port 465/SSL
- [x] ~~Cloudflare Worker for archive forwarding~~ - DEPLOYED but BROKEN (port 8080 blocked)
- [ ] **FIX INBOUND EMAIL** - Choose one:
  - [ ] Option 1: Set BACKUP_EMAIL in Worker to Gmail
  - [ ] Option 2: Disable Worker, use native Cloudflare Email Routing
  - [ ] Option 3: Route SMTP proxy through GCP
- [ ] Fix Worker/Proxy header mismatch (X-API-Key vs X-Proxy-Key)
- [ ] Fix Worker/Proxy body format mismatch (plain text vs JSON)
- [ ] DKIM configuration

---

## Architecture

### Inbound Mail Flow (BROKEN)
```
Internet → Cloudflare MX (port 25) → Email Worker → SMTP Proxy (8080) → Mailu
                                          │
                                          └── FAILS HERE
                                              Port 8080 blocked by Oracle
                                              BACKUP_EMAIL not configured
                                              Result: "Primary delivery failed..."
```

**Cloudflare Worker Configuration (email-forwarder):**
| Setting | Value | Status |
|---------|-------|--------|
| SMTP_PROXY_URL | http://smtp.diegonmarcos.com:8080/ | Port blocked |
| SMTP_PROXY_KEY | stalwart-proxy-key-2025 | - |
| BACKUP_EMAIL | (empty) | NOT SET |

**Additional Issues:**
- Worker sends `X-API-Key` header, proxy expects `X-Proxy-Key`
- Worker sends plain text body, proxy expects JSON `{from, to, raw}`

**Fix Options:**
1. Set `BACKUP_EMAIL` in Worker → forward to Gmail as fallback
2. Use Cloudflare Email Routing native forwarding (disable Worker)
3. Route SMTP proxy through GCP (ports not blocked)

### Outbound Mail Flow (WORKING)
```
Client → Mailu (port 465/SMTPS) → Postfix → OCI Email Delivery Relay → Internet
                                            [smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
```

**Note:** Oracle Cloud blocks outbound port 25, so all outbound mail is routed through OCI Email Delivery service via port 587 with STARTTLS.

## Configuration Files

- `/opt/mailu/mailu.env` - Main Mailu configuration
- `/opt/mailu/docker-compose.yml` - Docker Compose

## OCI Relay Configuration (in mailu.env)

```
RELAYHOST=[smtp.email.eu-marseille-1.oci.oraclecloud.com]:587
RELAYUSER=ocid1.user.oc1..aaaaaaaaadh3p7atydr4ga3yvr3noohaar4f5h62d7stidvzkzgmilyt4enq@ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq.lm.com
RELAYPASSWORD=.<zLnkRzJBv$2FiJaf-G
```

**Note:** The square brackets around the hostname and `:587` port are required. Oracle Cloud blocks outbound port 25, so Postfix must connect on port 587 with STARTTLS.

## Quick Access

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

## Why Mailu?

Stalwart Mail Server had complex relay configuration issues (split config between TOML and database).
Mailu offers:
- Simple env-based relay configuration (RELAYHOST, RELAYUSER, RELAYPASSWORD)
- Built-in webmail (Roundcube)
- Admin UI for user management
- Lightweight configuration without antivirus
