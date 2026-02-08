# NPM Proxy Host Configuration

## Create Proxy Host

Access NPM Admin: http://35.226.147.64:81

### Details Tab

| Field | Value |
|-------|-------|
| Domain Names | `db.diegonmarcos.com` |
| Scheme | `http` |
| Forward Hostname / IP | `10.0.0.2` |
| Forward Port | `8085` |
| Cache Assets | Off |
| Block Common Exploits | On |
| Websockets Support | On |

### SSL Tab

| Field | Value |
|-------|-------|
| SSL Certificate | Request a new SSL Certificate |
| Force SSL | On |
| HTTP/2 Support | On |
| HSTS Enabled | On |
| HSTS Subdomains | Off |

### Advanced Tab

```nginx
# Authelia Forward Auth Configuration
location /authelia {
    internal;
    set $upstream_authelia http://127.0.0.1:9091/api/verify;
    proxy_pass $upstream_authelia;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-Method $request_method;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
}

# Protect with Authelia
auth_request /authelia;
auth_request_set $user $upstream_http_remote_user;
auth_request_set $groups $upstream_http_remote_groups;
auth_request_set $name $upstream_http_remote_name;
auth_request_set $email $upstream_http_remote_email;

# Redirect to Authelia on 401
error_page 401 =302 https://auth.diegonmarcos.com/?rd=$scheme://$http_host$request_uri;

# Pass user info to backend
proxy_set_header Remote-User $user;
proxy_set_header Remote-Groups $groups;
proxy_set_header Remote-Name $name;
proxy_set_header Remote-Email $email;

# WebSocket support for NocoDB real-time features
location /socket.io/ {
    proxy_pass http://10.0.0.2:8085;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 86400;
}
```

## Verification

After creating the proxy host:

```bash
# Test SSL
curl -I https://db.diegonmarcos.com

# Should redirect to Authelia (302)
curl -I https://db.diegonmarcos.com 2>&1 | grep -E "HTTP|Location"
```
