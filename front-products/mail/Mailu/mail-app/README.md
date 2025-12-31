# Mail Server - Stalwart + Cloudflare Email Routing

Self-hosted email server for @diegonmarcos.com domain.

---

## Status

| Component | Status | Notes |
|-----------|--------|-------|
| Stalwart Mail Server | DEPLOYED | IMAP/SMTP working |
| Snappymail Webmail | DEPLOYED | Port 8888 |
| Cloudflare Email Routing | CONFIGURED | Gmail as primary |
| Thunderbird | CONFIGURED | Desktop client |

---

## Architecture

```
                    Internet
                       │
                       ▼
              ┌────────────────┐
              │   Cloudflare   │
              │  Email Routing │
              │   (port 25)    │
              └───────┬────────┘
                      │
         ┌────────────┴────────────┐
         │                         │
         ▼                         ▼
┌─────────────────┐      ┌─────────────────┐
│     Gmail       │      │    Stalwart     │
│   (PRIMARY)     │      │   (ARCHIVE)     │
│  Receives all   │      │  via Worker     │
│    emails       │      │   (planned)     │
└─────────────────┘      └─────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
                    ▼                       ▼
             ┌───────────┐          ┌───────────┐
             │ Snappymail│          │Thunderbird│
             │  Webmail  │          │  Desktop  │
             │  :8888    │          │   IMAP    │
             └───────────┘          └───────────┘
```

---

## Services

### Stalwart Mail Server

| Setting | Value |
|---------|-------|
| **Host** | 130.110.251.193 |
| **Admin Panel** | http://130.110.251.193:8080 |
| **IMAP** | Port 993 (SSL/TLS) |
| **SMTP** | Port 587 (STARTTLS) |
| **API** | Port 8080 |
| **Container** | stalwart-mail |

### Snappymail Webmail

| Setting | Value |
|---------|-------|
| **URL** | http://130.110.251.193:8888 |
| **Container** | snappymail |
| **Image** | djmaze/snappymail:latest |

---

## User Accounts

### Admin Account

| Field | Value |
|-------|-------|
| **Username** | admin |
| **Password** | 8HkSfq6mCW |
| **Role** | Superuser |
| **2FA** | Disabled |

### Email Account

| Field | Value |
|-------|-------|
| **Email** | me@diegonmarcos.com |
| **Username** | me |
| **Password** | diego123 |
| **IMAP Server** | 130.110.251.193:993 (SSL) |
| **SMTP Server** | 130.110.251.193:587 (STARTTLS) |

---

## Client Configuration

### Thunderbird

1. Add Account: `me@diegonmarcos.com`
2. Configure manually:
   - **IMAP**: mail.diegonmarcos.com, port 993, SSL/TLS
   - **SMTP**: mail.diegonmarcos.com, port 587, STARTTLS
   - **Username**: me
   - **Password**: diego123

### Mobile (K-9 Mail / FairEmail)

Same settings as Thunderbird above.

---

## Docker Compose

```yaml
version: "3.8"

services:
  stalwart:
    image: stalwartlabs/mail-server:latest
    container_name: stalwart-mail
    restart: unless-stopped
    ports:
      - "25:25"      # SMTP (blocked by Oracle)
      - "587:587"    # SMTP Submission
      - "993:993"    # IMAPS
      - "8080:8080"  # Admin/API
    volumes:
      - stalwart_data:/opt/stalwart-mail

  snappymail:
    image: djmaze/snappymail:latest
    container_name: snappymail
    restart: unless-stopped
    ports:
      - "8888:8888"
    environment:
      - SECURE_COOKIES=false

volumes:
  stalwart_data:
```

---

## DNS Configuration (Cloudflare)

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| MX | @ | route1.mx.cloudflare.net | - |
| MX | @ | route2.mx.cloudflare.net | - |
| MX | @ | route3.mx.cloudflare.net | - |
| A | mail | 130.110.251.193 | OFF |
| TXT | @ | v=spf1 include:_spf.mx.cloudflare.net ~all | - |

### Email Routing Rule

- **From**: *
- **To**: me@diegonmarcos.com
- **Action**: Forward to me@diegonmarcos.com (Gmail)

---

## OCI Security List

Ports opened for mail-app:

| Port | Protocol | Purpose |
|------|----------|---------|
| 587 | TCP | SMTP Submission |
| 993 | TCP | IMAPS |
| 8080 | TCP | Stalwart Admin |
| 8888 | TCP | Snappymail Webmail |

---

## Maintenance

### Check Container Status

```bash
ssh ubuntu@130.110.251.193 "sudo docker ps | grep -E 'stalwart|snappymail'"
```

### View Stalwart Logs

```bash
ssh ubuntu@130.110.251.193 "sudo docker logs stalwart-mail --tail 50"
```

### Restart Services

```bash
ssh ubuntu@130.110.251.193 "sudo docker restart stalwart-mail snappymail"
```

---

## TLS Certificates

**Current Status**: Let's Encrypt (ACME HTTP-01)

| Field | Value |
|-------|-------|
| **Domain** | mail.diegonmarcos.com |
| **Issuer** | Let's Encrypt E7 |
| **Valid Until** | Mar 7, 2026 |
| **Auto-Renew** | 30 days before expiry |

---

## Known Limitations

1. **Port 25 Blocked**: Oracle Cloud blocks outbound port 25
   - Use Cloudflare Email Routing for receiving
   - Use Gmail SMTP for sending

2. **No Direct Inbound**: Cloudflare Email Routing intercepts all MX traffic
   - Direct Stalwart receive requires alternative setup

---

## Future Improvements

- [x] Configure Let's Encrypt ACME for TLS
- [ ] Set up Cloudflare Worker to forward to Stalwart
- [ ] Configure DKIM signing for outbound
- [ ] Add alias addresses
- [ ] Enable calendar/contacts (CardDAV/CalDAV)

---

## Quick Reference

```bash
# SSH to server
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193

# Stalwart Admin
http://130.110.251.193:8080  (admin / 8HkSfq6mCW)

# Snappymail
http://130.110.251.193:8888  (me@diegonmarcos.com / diego123)

# Check mail ports
nc -zv mail.diegonmarcos.com 993  # IMAP
nc -zv mail.diegonmarcos.com 587  # SMTP

# Verify TLS certificate
openssl s_client -connect mail.diegonmarcos.com:993 -servername mail.diegonmarcos.com 2>/dev/null | openssl x509 -noout -subject -issuer
```

---

**Last Updated**: 2025-12-07
**VM**: oci-f-micro_1 (130.110.251.193)
**Status**: DEPLOYED
