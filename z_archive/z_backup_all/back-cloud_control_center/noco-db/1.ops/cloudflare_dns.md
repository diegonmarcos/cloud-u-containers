# Cloudflare DNS Configuration

## Add DNS Record

1. Login to Cloudflare Dashboard: https://dash.cloudflare.com
2. Select domain: `diegonmarcos.com`
3. Go to DNS → Records
4. Add record:

| Type | Name | Content | Proxy | TTL |
|------|------|---------|-------|-----|
| A | db | 35.226.147.64 | Proxied (orange cloud) | Auto |

## Verification

```bash
# Check DNS propagation
dig db.diegonmarcos.com +short
# Should return Cloudflare IP (not 35.226.147.64 due to proxy)

# Check via nslookup
nslookup db.diegonmarcos.com

# Test HTTPS (after NPM configured)
curl -I https://db.diegonmarcos.com
```

## SSL/TLS Settings

Ensure Cloudflare SSL settings match NPM:

1. Go to SSL/TLS → Overview
2. Set encryption mode to **Full (strict)**

This ensures:
- Browser → Cloudflare: HTTPS
- Cloudflare → NPM: HTTPS (Let's Encrypt cert)
