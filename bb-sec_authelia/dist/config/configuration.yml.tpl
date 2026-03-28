---
theme: dark

server:
  address: tcp://0.0.0.0:9091/authelia
  endpoints:
    authz:
      forward-auth:
        implementation: ForwardAuth
        authn_strategies:
          - name: HeaderAuthorization
            schemes:
              - Bearer
          - name: CookieSession
      auth-request:
        implementation: AuthRequest
        authn_strategies:
          - name: HeaderAuthorization
            schemes:
              - Bearer
          - name: CookieSession

log:
  level: info

identity_validation:
  reset_password:
    jwt_secret: ${AUTHELIA_JWT_SECRET}

authentication_backend:
  file:
    path: /config/users_database.yml
    watch: true

access_control:
  default_policy: two_factor
  rules:
    - domain: auth.diegonmarcos.com
      policy: bypass
    - domain: db.diegonmarcos.com
      resources:
        - "^/api/.*"
      policy: bypass
    - domain: db.diegonmarcos.com
      policy: two_factor
    - domain: "*.diegonmarcos.com"
      policy: two_factor

session:
  name: authelia_session
  secret: ${AUTHELIA_SESSION_SECRET}
  cookies:
    - name: authelia_session
      domain: diegonmarcos.com
      authelia_url: https://auth.diegonmarcos.com
      inactivity: 5m
      expiration: 1h
      remember_me: 30d
  redis:
    host: localhost
    password: ${AUTHELIA_REDIS_PASSWORD}
    port: 6380

regulation:
  max_retries: 3
  find_time: 10m
  ban_time: 15m

storage:
  encryption_key: ${AUTHELIA_STORAGE_ENCRYPTION_KEY}
  local:
    path: /data/db.sqlite3

notifier:
  disable_startup_check: true
  smtp:
    address: submissions://10.0.0.3:465
    username: no-reply@diegonmarcos.com
    password: ${AUTHELIA_SMTP_PASSWORD}
    sender: "Authelia <no-reply@diegonmarcos.com>"
    tls:
      server_name: mail.diegonmarcos.com

webauthn:
  disable: false
  display_name: diegonmarcos.com
  attestation_conveyance_preference: indirect
  timeout: 60s

totp:
  issuer: diegonmarcos.com
  period: 30
  skew: 1

identity_providers:
  oidc:
    hmac_secret: ${AUTHELIA_OIDC_HMAC_SECRET}
    lifespans:
      access_token: 87600h
      refresh_token: 87600h
    jwks:
      - key_id: main
        algorithm: RS256
        use: sig
        key: __JWKS_KEY__
    cors:
      endpoints:
        - authorization
        - token
        - revocation
        - introspection
        - userinfo
      allowed_origins_from_client_redirect_uris: true
    clients:
      - client_id: oauth2-proxy-npm
        consent_mode: explicit
        client_name: NPM Proxy Manager
        client_secret: ${AUTHELIA_OIDC_CLIENT_NPM_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://proxy.diegonmarcos.com/oauth2/callback
        scopes:
          - openid
          - profile
          - email
          - groups
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256

      - client_id: nocodb
        consent_mode: explicit
        client_name: NocoDB Database
        client_secret: ${AUTHELIA_OIDC_CLIENT_NOCODB_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://db.diegonmarcos.com/api/v1/auth/oidc/callback
          - https://db.diegonmarcos.com/api/v2/auth/oidc/callback
        scopes:
          - openid
          - profile
          - email
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256

      - client_id: cloudflare-health-c3-api
        consent_mode: explicit
        client_name: Cloudflare Worker Health Check
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/

      - client_id: claude-admin
        consent_mode: explicit
        client_name: Claude AI Agent
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://*.diegonmarcos.com/
          - https://diegonmarcos.com/

      - client_id: cloud-admin
        consent_mode: explicit
        client_name: Cloud Admin
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://*.diegonmarcos.com/
          - https://diegonmarcos.com/
          - https://api.diegonmarcos.com/

      - client_id: claude-opus
        consent_mode: explicit
        client_name: Claude Opus Agent
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://*.diegonmarcos.com/
          - https://diegonmarcos.com/
          - https://api.diegonmarcos.com/

      - client_id: claude-sonnet
        consent_mode: explicit
        client_name: Claude Sonnet Agent
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://*.diegonmarcos.com/
          - https://diegonmarcos.com/
          - https://api.diegonmarcos.com/

      - client_id: claude-haiku
        consent_mode: explicit
        client_name: Claude Haiku Agent
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://*.diegonmarcos.com/
          - https://diegonmarcos.com/
          - https://api.diegonmarcos.com/

      - client_id: dagu-ops
        consent_mode: explicit
        client_name: Dagu Workflow Engine
        client_secret: ${AUTHELIA_OIDC_CLIENT_DAGU_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/

      - client_id: dagu-cc
        client_name: Dagu Service Account
        client_secret: ${AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET}
        public: false
        authorization_policy: one_factor
        grant_types:
          - client_credentials
        scopes:
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/

      - client_id: monitoring-read
        consent_mode: explicit
        client_name: Monitoring Read-Only
        client_secret: ${AUTHELIA_OIDC_CLIENT_MONITORING_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/

      - client_id: mattermost-ops
        consent_mode: explicit
        client_name: Mattermost Bot
        client_secret: ${AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/
          - https://rss.diegonmarcos.com/

      - client_id: mattermost-cc
        client_name: Mattermost Service Account
        client_secret: ${AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET}
        public: false
        authorization_policy: one_factor
        grant_types:
          - client_credentials
        scopes:
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/
          - https://rss.diegonmarcos.com/

      - client_id: c3-infra-mcp-api
        client_name: C3 Infra MCP API
        client_secret: ${AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET}
        public: false
        grant_types:
          - client_credentials
        scopes:
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        access_token_signed_response_alg: RS256
        audience:
          - https://api.diegonmarcos.com/

      - client_id: cli
        consent_mode: explicit
        client_name: CLI Access
        client_secret: ${AUTHELIA_OIDC_CLIENT_CLI_SECRET}
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - http://localhost:8400/callback
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        response_modes:
          - form_post
        scopes:
          - offline_access
          - authelia.bearer.authz
        token_endpoint_auth_method: client_secret_basic
        require_pushed_authorization_requests: true
        require_pkce: true
        pkce_challenge_method: S256
        access_token_signed_response_alg: RS256
        audience:
          - https://*.diegonmarcos.com/
          - https://diegonmarcos.com/
