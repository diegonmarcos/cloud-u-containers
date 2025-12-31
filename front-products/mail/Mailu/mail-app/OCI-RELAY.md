# OCI Email Delivery Relay Configuration

**Date Configured:** 2025-12-08
**Status:** WORKING

## Why OCI Relay?

Oracle Cloud Infrastructure (OCI) blocks outbound port 25 by default to prevent spam. This means Stalwart cannot send emails directly to external mail servers (MX records). The solution is to use OCI Email Delivery service as an SMTP relay.

## Configuration Overview

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
| Username | `ocid1.user.oc1..aaaaaaaaadh3p7atydr4ga3yvr3noohaar4f5h62d7stidvzkzgmilyt4enq@ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq.xr.com` |
| Password | *(stored in Stalwart config)* |

## Stalwart Configuration

### Method 1: Via config.toml (Persistent)

Add to `/opt/stalwart/etc/config.toml`:

```toml
# OCI Email Delivery Relay Route
[queue.route."oci-relay"]
type = "relay"
address = "smtp.email.eu-marseille-1.oci.oraclecloud.com"
port = 587
protocol = "smtp"

[queue.route."oci-relay".tls]
implicit = false
allow-invalid-certs = false

[queue.route."oci-relay".auth]
username = "ocid1.user.oc1..aaaaaaaaadh3p7atydr4ga3yvr3noohaar4f5h62d7stidvzkzgmilyt4enq@ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq.xr.com"
secret = "YOUR_SMTP_PASSWORD_HERE"

# Route all outbound mail through OCI relay
[queue.outbound]
next-hop = "'oci-relay'"

# Disable DANE and MTA-STS since we're using a relay
[queue.outbound.limits]
dane = "disable"
mta-sts = "disable"
```

### Method 2: Via REST API (Database)

```bash
# Set routing strategy
curl -X POST -u admin:PASSWORD \
  'http://127.0.0.1:8080/api/settings' \
  -H 'Content-Type: application/json' \
  -d '[{"key": "queue.strategy.route", "value": "'\''oci-relay'\''"}]'

# View current settings
curl -u admin:PASSWORD 'http://127.0.0.1:8080/api/settings?prefix=queue'
```

**Note:** Database settings take precedence over config.toml settings.

## OCI Setup Steps

### 1. Create Approved Sender

```bash
# List existing senders
oci email sender list --compartment-id <compartment-id>

# Create approved sender for your domain
oci email sender create \
  --compartment-id <compartment-id> \
  --email-address "me@diegonmarcos.com"
```

### 2. Create SMTP Credentials

```bash
# List existing credentials
oci iam smtp-credential list --user-id <user-id>

# Create new SMTP credential
oci iam smtp-credential create \
  --user-id <user-id> \
  --description "Stalwart Mail Server"
```

### 3. Configure DNS Records

Ensure the following DNS records exist for your domain:

- **SPF:** `v=spf1 include:rp.oracleemaildelivery.com ~all`
- **DKIM:** Configure via OCI Console (Email Delivery > DKIM)

## Testing

### Test SMTP Connection

```bash
# From the server
openssl s_client -connect smtp.email.eu-marseille-1.oci.oraclecloud.com:587 -starttls smtp
```

### Test Email Sending via Stalwart

```python
import smtplib
from email.mime.text import MIMEText

msg = MIMEText("Test email body")
msg['Subject'] = "Test Email"
msg['From'] = "me@diegonmarcos.com"
msg['To'] = "recipient@example.com"

with smtplib.SMTP('mail.diegonmarcos.com', 587) as server:
    server.starttls()
    server.login('me@diegonmarcos.com', 'PASSWORD')
    server.send_message(msg)
```

### Check Stalwart Queue

```bash
# View queue
curl -u admin:PASSWORD 'http://127.0.0.1:8080/api/queue/messages?page=0&limit=10'

# View logs
sudo docker exec stalwart-mail tail -100 /opt/stalwart/logs/stalwart.log.$(date +%Y-%m-%d)
```

## Troubleshooting

### Common Issues

1. **Messages stuck in queue going to direct MX**
   - Clear old messages from queue
   - Verify `queue.outbound.next-hop` is set correctly
   - Check both config.toml and database settings

2. **Authentication failures**
   - Verify SMTP credentials are correct
   - Username should be the full OCID format
   - Password may contain special characters - ensure proper escaping

3. **Connection timeouts to port 25**
   - Expected behavior - OCI blocks port 25 outbound
   - Must use port 587 via OCI relay

4. **"Relay not allowed" error**
   - Ensure you're connecting to submission port (587), not SMTP port (25)
   - Authenticate before sending

### Viewing Delivery Logs

```bash
# SSH to server
ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193

# Check delivery logs
sudo docker exec stalwart-mail tail -f /opt/stalwart/logs/stalwart.log.$(date +%Y-%m-%d) | grep -E "(delivery|relay|smtp.email)"
```

## Architecture Diagram

```
                           ┌─────────────────────────────────┐
                           │          OCI Cloud              │
                           │                                 │
┌──────────────┐           │  ┌──────────────────────────┐  │
│ Thunderbird/ │           │  │    Stalwart Mail Server  │  │
│ Mail Client  │ ──587───► │  │    (130.110.251.193)     │  │
└──────────────┘  STARTTLS │  └───────────┬──────────────┘  │
                           │              │                 │
                           │              │ 587/STARTTLS    │
                           │              ▼                 │
                           │  ┌──────────────────────────┐  │
                           │  │  OCI Email Delivery      │  │
                           │  │  (eu-marseille-1)        │  │
                           │  └───────────┬──────────────┘  │
                           │              │                 │
                           └──────────────┼─────────────────┘
                                          │ 25/SMTP
                                          ▼
                           ┌──────────────────────────────────┐
                           │     Recipient Mail Server        │
                           │     (Gmail, Outlook, etc.)       │
                           └──────────────────────────────────┘
```

## References

- [OCI Email Delivery Documentation](https://docs.oracle.com/en-us/iaas/Content/Email/home.htm)
- [Stalwart Mail Server Documentation](https://stalw.art/docs/)
- [Stalwart Relay Configuration](https://stalw.art/docs/smtp/outbound/routing)
