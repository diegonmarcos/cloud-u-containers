# Introspect Proxy Deployment Guide

Token introspection proxy for Authelia CLI authentication.

## Problem Solved

Authelia's `authelia.bearer.authz` forward-auth fails for CLI clients due to issuer mismatch
(it uses X-Forwarded-Host instead of the configured issuer). This proxy uses Authelia's
standard OIDC token introspection endpoint which works correctly.

## Architecture

```
CLI/API Client
    │
    │ Authorization: Bearer <token>
    ▼
┌─────────────────────────────────────────────────┐
│  NPM (nginx)                                     │
│                                                  │
│  location / {                                    │
│    auth_request /_auth/bearer;  ───────────────┐│
│    ...                                          ││
│  }                                              ││
│                                                 ││
│  location = /_auth/bearer {                    ◄┘│
│    proxy_pass introspect-proxy:4182/auth;       │
│  }                                              │
└─────────────────────────────────────────────────┘
    │
    │ POST /api/oidc/introspection
    ▼
┌─────────────────────────────────────────────────┐
│  Introspect Proxy (this service)                │
│                                                  │
│  1. Extract Bearer token from header             │
│  2. Call Authelia introspection endpoint         │
│  3. If active=true → 200 + X-Auth-* headers     │
│  4. If active=false → 401                       │
└─────────────────────────────────────────────────┘
    │
    │ POST with client credentials
    ▼
┌─────────────────────────────────────────────────┐
│  Authelia                                        │
│  /api/oidc/introspection                        │
│                                                  │
│  Returns: {"active": true, "username": "...", } │
└─────────────────────────────────────────────────┘
```

## Prerequisites

### 1. Authelia OIDC Client Configuration

Ensure the `cli` client is configured in Authelia with introspection enabled:

```yaml
# In authelia configuration.yml, under identity_providers.oidc.clients:

- client_id: 'cli'
  client_name: 'CLI Client'
  client_secret: '$pbkdf2-sha512$...'  # Hash of: cli-secret-2026-secure-token-for-automation
  public: false
  authorization_policy: 'two_factor'
  scopes:
    - 'openid'
    - 'profile'
    - 'email'
  grant_types:
    - 'authorization_code'
    - 'refresh_token'
  response_types:
    - 'code'
  token_endpoint_auth_method: 'client_secret_basic'
  introspection_signed_response_alg: 'none'
```

### 2. Environment Setup

Create `.env` file in the introspect-proxy directory:

```bash
AUTHELIA_CLI_SECRET=cli-secret-2026-secure-token-for-automation
```

## Deployment Steps

### On gcp-f-micro_1 (35.226.147.64)

```bash
# 1. SSH to server
gcloud compute ssh arch-1 --zone us-central1-a

# 2. Create directory
mkdir -p /opt/introspect-proxy
cd /opt/introspect-proxy

# 3. Copy files (from local, or clone from repo)
# - Dockerfile
# - docker-compose.yml
# - app/main.py
# - app/requirements.txt
# - .env (with AUTHELIA_CLI_SECRET)

# 4. Build and start
docker compose build
docker compose up -d

# 5. Verify
curl http://localhost:4182/health  # Should return "OK"
docker compose logs
```

### Configure NPM Proxy Hosts

For each service that needs Bearer token auth:

1. Go to NPM Admin → Proxy Hosts → Edit → Advanced tab
2. Add the nginx config from `1.ops/npm_advanced_config.md`
3. Save and test

## Testing

### 1. Direct introspection test (already verified)

```bash
TOKEN=$(jq -r .access_token ~/authelia_tokens.json)

curl -s -X POST https://auth.diegonmarcos.com/api/oidc/introspection \
  -u "cli:cli-secret-2026-secure-token-for-automation" \
  -d "token=$TOKEN"

# Returns: {"active": true, "username": "me@diegonmarcos.com", ...}
```

### 2. Introspect-proxy health

```bash
curl http://localhost:4182/health
# Returns: OK
```

### 3. Introspect-proxy auth (from same server)

```bash
# Without token - should 401
curl -v http://localhost:4182/auth
# Returns: 401 No Bearer token

# With token - should 200
TOKEN=$(jq -r .access_token ~/authelia_tokens.json)
curl -v -H "Authorization: Bearer $TOKEN" http://localhost:4182/auth
# Returns: 200 OK with X-Auth-User header
```

### 4. End-to-end via NPM

```bash
# After configuring NPM advanced config
TOKEN=$(jq -r .access_token ~/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://analytics.diegonmarcos.com/
# Should return Matomo HTML, not redirect
```

## Troubleshooting

### 502 from introspect-proxy

- Check Authelia is reachable: `curl https://auth.diegonmarcos.com/api/health`
- Verify CLIENT_SECRET is correct in .env
- Check logs: `docker compose logs introspect-proxy`

### 401 with valid token

- Token may be expired (default 1h). Get a new token.
- Verify token with direct introspection test above
- Check `cli` client has introspection enabled in Authelia

### NPM auth_request errors

- Ensure introspect-proxy is on `proxy_network`
- Verify NPM can reach `introspect-proxy:4182`
- Check NPM error logs: `docker logs npm`

## Files

```
introspect-proxy/
├── DEPLOY.md              # This file
├── Dockerfile             # Alpine Python image
├── docker-compose.yml     # Service definition
├── app/
│   ├── main.py           # Flask application
│   └── requirements.txt  # Python dependencies
└── 1.ops/
    ├── build.sh          # Build/deploy script
    └── npm_advanced_config.md  # NPM configuration examples
```

## Security Notes

- The introspect-proxy is bound to 127.0.0.1 and only accessible via Docker network
- CLIENT_SECRET should be stored securely (not in git)
- Consider rotating the CLI client secret periodically
- Monitor for failed auth attempts in logs
