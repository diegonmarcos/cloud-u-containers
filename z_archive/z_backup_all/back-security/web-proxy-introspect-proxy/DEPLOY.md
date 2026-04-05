# Introspect Proxy - Authelia CLI Authentication

Token introspection proxy for Authelia CLI/API authentication via Bearer tokens.

## Problem Solved

Authelia's `authelia.bearer.authz` forward-auth fails for CLI clients due to issuer mismatch
(it uses X-Forwarded-Host instead of the configured issuer). This proxy validates tokens via
Authelia's standard OIDC introspection endpoint which works correctly.

## Architecture

```
CLI/API Client
    │
    │ Authorization: Bearer <token>
    ▼
┌─────────────────────────────────────────────────┐
│  NPM (nginx + Lua)                               │
│                                                  │
│  1. Check for Bearer header                      │
│  2. If Bearer: validate via introspect-proxy    │
│  3. If no Bearer: validate via Authelia cookie  │
│  4. 200 → allow, 401 → redirect to Authelia     │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│  Introspect Proxy (:4182)                        │
│                                                  │
│  POST to Authelia /api/oidc/introspection       │
│  Returns: 200 + X-Auth-* headers (valid)        │
│           401 (invalid/expired)                  │
└─────────────────────────────────────────────────┘
```

## Deployed Services

| Service | Domain | Config | Status |
|---------|--------|--------|--------|
| Analytics (Matomo) | analytics.diegonmarcos.com | 3.conf | ✅ Bearer + Authelia |
| Database (NocoDB) | db.diegonmarcos.com | 18.conf | ✅ Bearer + Authelia |
| IDE (Code Server) | ide.diegonmarcos.com | 17.conf | ✅ Bearer + Authelia |

## Prerequisites

### Authelia OIDC Client Configuration

Ensure the `cli` client is configured in Authelia with introspection enabled:

```yaml
# In authelia configuration.yml, under identity_providers.oidc.clients:

- client_id: 'cli'
  client_name: 'CLI Client'
  client_secret: '$pbkdf2-sha512$...'  # Hash of: <redacted-secret>
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

## Files

```
introspect-proxy/
├── DEPLOY.md              # This file
├── Dockerfile             # Alpine Python image
├── docker-compose.yml     # Service definition
├── .env.example          # Environment template
├── app/
│   ├── main.py           # Flask application
│   └── requirements.txt  # Python dependencies
└── 1.ops/
    ├── build.sh          # Build/deploy script
    └── npm-configs/      # Working NPM proxy host configs
        ├── analytics.conf  # analytics.diegonmarcos.com
        ├── db.conf         # db.diegonmarcos.com
        └── ide.conf        # ide.diegonmarcos.com
```

## Deployment

### Introspect Proxy (on gcp-f-micro_1)

```bash
# SSH to server
gcloud compute ssh arch-1 --zone us-central1-a

# Already deployed at /opt/introspect-proxy
# Container: introspect-proxy
# Network: npm_default
# Port: 127.0.0.1:4182

# To redeploy:
cd /opt/introspect-proxy
echo 'AUTHELIA_CLI_SECRET=<redacted-secret>
DEBUG=true' > .env
docker-compose down && docker-compose up -d

# Verify
docker exec npm curl -s http://introspect-proxy:4182/health  # Should return "OK"
```

### NPM Proxy Host Configs

Configs are stored in `1.ops/npm-configs/`. To update a service:

```bash
# Copy config to server
gcloud compute scp 1.ops/npm-configs/analytics.conf arch-1:/tmp/

# Deploy to NPM
gcloud compute ssh arch-1 --zone us-central1-a --command "
  docker cp /tmp/analytics.conf npm:/data/nginx/proxy_host/3.conf
  docker exec npm nginx -t && docker exec npm nginx -s reload
"
```

## How It Works

The nginx config uses Lua (`access_by_lua_block`) to:

1. Check if `Authorization: Bearer` header exists
2. If Bearer token present:
   - Set `X-Bearer-Token` header (for subrequest to access)
   - Call `/_auth/bearer` internal location → introspect-proxy
   - If valid (200): set user headers, allow request
   - If invalid (401): redirect to Authelia login
3. If no Bearer token:
   - Call `/_auth/authelia` internal location → Authelia forward-auth
   - If valid (200): set user headers, allow request
   - If invalid: redirect to Authelia login

## Testing

### Test Auth Flow

```bash
# From gcp-f-micro_1:

# No auth → redirect to Authelia (302)
curl -sk --resolve 'analytics.diegonmarcos.com:443:127.0.0.1' \
  -o /dev/null -w '%{http_code}\n' https://analytics.diegonmarcos.com/
# Returns: 302

# Invalid Bearer → redirect to Authelia (302)
curl -sk --resolve 'analytics.diegonmarcos.com:443:127.0.0.1' \
  -o /dev/null -w '%{http_code}\n' \
  -H 'Authorization: Bearer invalid' https://analytics.diegonmarcos.com/
# Returns: 302

# Valid Bearer → success (200)
TOKEN=$(jq -r .access_token ~/authelia_tokens.json)
curl -sk --resolve 'analytics.diegonmarcos.com:443:127.0.0.1' \
  -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" https://analytics.diegonmarcos.com/
# Returns: 200
```

### Direct Introspection Test

```bash
TOKEN=$(jq -r .access_token ~/authelia_tokens.json)

curl -s -X POST https://auth.diegonmarcos.com/api/oidc/introspection \
  -u "cli:<redacted-secret>" \
  -d "token=$TOKEN"

# Returns: {"active": true, "username": "me@diegonmarcos.com", ...}
```

## Obtaining Tokens

Use the Authelia OIDC authorization code flow:

```bash
# 1. Start auth flow (open in browser)
open "https://auth.diegonmarcos.com/api/oidc/authorization?client_id=cli&response_type=code&scope=openid%20profile%20email&redirect_uri=http://localhost:8085/callback"

# 2. Complete login in browser (2FA), get code from redirect URL

# 3. Exchange code for tokens
curl -X POST https://auth.diegonmarcos.com/api/oidc/token \
  -u "cli:<redacted-secret>" \
  -d "grant_type=authorization_code&code=<CODE>&redirect_uri=http://localhost:8085/callback"

# 4. Save and use access_token from response
```

## Troubleshooting

### 502 from introspect-proxy
- Check Authelia is reachable: `curl https://auth.diegonmarcos.com/api/health`
- Verify CLIENT_SECRET is correct: check `/opt/introspect-proxy/.env`
- Check logs: `docker logs introspect-proxy`

### 401 with valid token
- Token may be expired (default 1h). Get a new token.
- Verify `cli` client has introspection enabled in Authelia config

### NPM returns 500
- Check nginx error logs: `docker exec npm tail /data/logs/proxy-host-N_error.log`
- Verify introspect-proxy is running: `docker ps | grep introspect`
- Verify network connectivity: `docker exec npm curl http://introspect-proxy:4182/health`

### Lua errors in nginx logs
- Check syntax in the nginx config
- Verify `set $auth_user "";` variables are defined before the Lua block

## NPM Config Reference

Key nginx locations for Bearer auth:

```nginx
# Bearer token validation via introspect-proxy
location = /_auth/bearer {
    internal;
    proxy_pass http://introspect-proxy:4182/auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Authorization $http_x_bearer_token;
}

# Authelia cookie validation
location = /_auth/authelia {
    internal;
    proxy_pass http://authelia:9091/api/authz/forward-auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header Cookie $http_cookie;
    # ... other X-Forwarded-* headers
}

# Main location with Lua auth
location / {
    set $auth_user "";
    set $auth_email "";
    set $auth_groups "";

    access_by_lua_block {
      local auth_header = ngx.var.http_authorization or ""
      if string.match(auth_header, "^Bearer ") then
        ngx.req.set_header("X-Bearer-Token", auth_header)
        local res = ngx.location.capture("/_auth/bearer")
        if res.status == 200 then
          ngx.var.auth_user = res.header["X-Auth-User"] or ""
          return
        else
          return ngx.redirect("https://auth.diegonmarcos.com/?rd=...")
        end
      else
        local res = ngx.location.capture("/_auth/authelia")
        if res.status == 200 then
          ngx.var.auth_user = res.header["Remote-User"] or ""
          return
        else
          return ngx.redirect("https://auth.diegonmarcos.com/?rd=...")
        end
      end
    }

    proxy_set_header Remote-User $auth_user;
    proxy_pass http://backend:port;
}
```

## Security Notes

- The introspect-proxy is bound to 127.0.0.1 and only accessible via Docker network
- CLIENT_SECRET should be stored securely (not in git, use .env file)
- Consider rotating the CLI client secret periodically
- Monitor for failed auth attempts in logs
- Tokens expire after 1 hour by default
