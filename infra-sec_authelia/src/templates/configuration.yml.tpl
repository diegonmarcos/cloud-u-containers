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

authentication_backend:
  file:
    path: /tmp/users_database.yml
    watch: true

access_control:
  default_policy: two_factor
  rules:
    - domain: @DOMAIN@
      policy: bypass
@ACCESS_CONTROL_RULES@
    - domain: "*.@BASE_DOMAIN@"
      policy: two_factor

identity_validation:
  reset_password:
    jwt_secret: '{{ secret "/run/secrets/AUTHELIA_JWT_SECRET" }}'

session:
  secret: '{{ secret "/run/secrets/AUTHELIA_SESSION_SECRET" }}'
  name: authelia_session
  cookies:
    - name: authelia_session
      domain: @BASE_DOMAIN@
      authelia_url: https://@DOMAIN@
      inactivity: 5m
      expiration: 1h
      remember_me: 30d
  redis:
    host: redis
    port: @REDIS_PORT@
    password: '{{ secret "/run/secrets/AUTHELIA_REDIS_PASSWORD" }}'

regulation:
  max_retries: 3
  find_time: 10m
  ban_time: 15m

storage:
  encryption_key: '{{ secret "/run/secrets/AUTHELIA_STORAGE_ENCRYPTION_KEY" }}'
  local:
    path: /data/db.sqlite3

notifier:
  disable_startup_check: true
  smtp:
    address: submissions://@MADDY_IP@:@MADDY_SMTP_PORT@
    username: no-reply@@BASE_DOMAIN@
    password: '{{ secret "/run/secrets/AUTHELIA_SMTP_PASSWORD" }}'
    sender: "Authelia <no-reply@@BASE_DOMAIN@>"
    tls:
      server_name: mail.@BASE_DOMAIN@

webauthn:
  disable: false
  display_name: @BASE_DOMAIN@
  attestation_conveyance_preference: indirect
  timeout: 60s

totp:
  issuer: @BASE_DOMAIN@
  period: 30
  skew: 1

identity_providers:
  oidc:
    hmac_secret: '{{ secret "/run/secrets/AUTHELIA_OIDC_HMAC_SECRET" }}'
    lifespans:
      access_token: 87600h
      refresh_token: 87600h
    cors:
      endpoints:
        - authorization
        - token
        - revocation
        - introspection
        - userinfo
      allowed_origins_from_client_redirect_uris: true
    clients:
@OIDC_CLIENTS@
