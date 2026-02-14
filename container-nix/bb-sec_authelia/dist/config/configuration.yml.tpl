---
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
    - domain: vault.diegonmarcos.com
      resources:
        - "^/api.*"
        - "^/identity.*"
        - "^/icons.*"
        - "^/notifications.*"
        - "^/attachments.*"
      policy: bypass
    - domain: vault.diegonmarcos.com
      resources:
        - "^/admin.*"
      policy: two_factor
    - domain: vault.diegonmarcos.com
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
    host: authelia-redis
    password: ${AUTHELIA_REDIS_PASSWORD}
    port: 6379

regulation:
  max_retries: 3
  find_time: 10m
  ban_time: 15m

storage:
  encryption_key: ${AUTHELIA_STORAGE_ENCRYPTION_KEY}
  local:
    path: /config/db.sqlite3

notifier:
  smtp:
    address: smtp://10.0.0.3:587
    username: me@diegonmarcos.com
    password: ${AUTHELIA_SMTP_PASSWORD}
    sender: "Authelia <me@diegonmarcos.com>"
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
      access_token: 8760h
      refresh_token: 8760h
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
          - https://db.diegonmarcos.com/
          - https://analytics.diegonmarcos.com/
          - https://auth.diegonmarcos.com/
          - https://cal.diegonmarcos.com/
          - https://ide.diegonmarcos.com/
          - https://mail.diegonmarcos.com/
          - https://photos.diegonmarcos.com/
          - https://proxy.diegonmarcos.com/
          - https://rss.diegonmarcos.com/
          - https://sync.diegonmarcos.com/
          - https://vault.diegonmarcos.com/
