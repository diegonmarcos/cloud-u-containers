# NPM Advanced Configuration for Bearer Token Auth

Add this to the **Advanced** tab of each proxy host that needs Bearer token authentication.

## For analytics.diegonmarcos.com (and similar services)

```nginx
# ═══════════════════════════════════════════════════════════════════════════
# Bearer Token Authentication via Introspection Proxy
# ═══════════════════════════════════════════════════════════════════════════

# Internal auth location - calls introspect-proxy
location = /_auth/bearer {
    internal;

    # Forward the Authorization header to introspect-proxy
    proxy_pass http://introspect-proxy:4182/auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Authorization $http_authorization;
    proxy_set_header X-Original-URI $request_uri;
}

# Main location with dual auth support
location / {
    # Check for Bearer token first
    # If present and valid: 200 + auth headers
    # If absent or invalid: 401 -> triggers @authelia_fallback
    set $auth_method "none";

    if ($http_authorization ~* "^Bearer ") {
        set $auth_method "bearer";
    }

    # When Bearer token present, validate via introspect-proxy
    auth_request /_auth/bearer;
    auth_request_set $auth_user $upstream_http_x_auth_user;
    auth_request_set $auth_email $upstream_http_x_auth_email;

    # On 401, fall back to Authelia cookie auth
    error_page 401 = @authelia_fallback;

    # Pass auth info to backend
    proxy_set_header Remote-User $auth_user;
    proxy_set_header Remote-Email $auth_email;

    # Standard proxy settings (NPM adds these, shown for reference)
    proxy_pass $forward_scheme://$server:$port;
}

# Fallback for browser users without Bearer token
location @authelia_fallback {
    # Standard Authelia forward-auth
    auth_request /authelia;
    auth_request_set $target_url $scheme://$http_host$request_uri;
    error_page 401 =302 https://auth.diegonmarcos.com/?rd=$target_url;

    proxy_pass $forward_scheme://$server:$port;
}

# Authelia verification endpoint
location /authelia {
    internal;
    proxy_pass http://authelia:9091/api/verify;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
}
```

## Simpler Version (Bearer-only, no Authelia fallback)

For services that only need CLI/API access:

```nginx
# Bearer-only authentication
location = /_auth/bearer {
    internal;
    proxy_pass http://introspect-proxy:4182/auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Authorization $http_authorization;
}

location / {
    auth_request /_auth/bearer;
    auth_request_set $auth_user $upstream_http_x_auth_user;

    # 401 without Bearer token
    error_page 401 = @no_bearer;

    proxy_set_header Remote-User $auth_user;
    proxy_pass $forward_scheme://$server:$port;
}

location @no_bearer {
    return 401 '{"error": "Bearer token required"}';
    add_header Content-Type application/json;
}
```

## Testing

```bash
# Get token (if you have authelia_tokens.json from OIDC flow)
TOKEN=$(jq -r .access_token ~/authelia_tokens.json)

# Test protected endpoint
curl -H "Authorization: Bearer $TOKEN" https://analytics.diegonmarcos.com/

# Should return Matomo content, not redirect
```
