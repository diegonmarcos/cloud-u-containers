{
  description = "Authelia 2FA Authentication - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # Configuration options (non-secret)
    config = {
      domain = "auth.diegonmarcos.com";
      base_domain = "diegonmarcos.com";
      container_name = "authelia";
      image = "authelia/authelia:latest";
      port = 9091;
      timezone = "Europe/Madrid";
    };

    # Generate docker-compose.yml (authelia + redis)
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        authelia:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
          volumes:
            - ./config:/config
          entrypoint: /config/init.sh
          ports:
            - "${toString config.port}:9091"
          networks:
            - auth-net
            - npm_default
          depends_on:
            - redis

        redis:
          image: redis:7-bookworm
          container_name: authelia-redis
          command: redis-server --requirepass ''\${AUTHELIA_REDIS_PASSWORD}
          ports:
            - "127.0.0.1:6379:6379"
          restart: unless-stopped
          networks:
            - auth-net

      networks:
        auth-net:
          driver: bridge
        npm_default:
          external: true
    '';

    # Generate authelia configuration.yml template
    # Secrets use ''${VAR} placeholders, substituted by init.sh via envsubst
    mkAutheliaConfig = pkgs: pkgs.writeText "configuration.yml.tpl" ''
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
          jwt_secret: ''\${AUTHELIA_JWT_SECRET}

      authentication_backend:
        file:
          path: /config/users_database.yml
          watch: true

      access_control:
        default_policy: two_factor
        rules:
          - domain: ${config.domain}
            policy: bypass
          - domain: vault.${config.base_domain}
            resources:
              - "^/api.*"
              - "^/identity.*"
              - "^/icons.*"
              - "^/notifications.*"
              - "^/attachments.*"
            policy: bypass
          - domain: vault.${config.base_domain}
            resources:
              - "^/admin.*"
            policy: two_factor
          - domain: vault.${config.base_domain}
            policy: bypass
          - domain: db.${config.base_domain}
            resources:
              - "^/api/.*"
            policy: bypass
          - domain: db.${config.base_domain}
            policy: two_factor
          - domain: "*.${config.base_domain}"
            policy: two_factor

      session:
        name: authelia_session
        secret: ''\${AUTHELIA_SESSION_SECRET}
        cookies:
          - name: authelia_session
            domain: ${config.base_domain}
            authelia_url: https://${config.domain}
            inactivity: 5m
            expiration: 1h
            remember_me: 30d
        redis:
          host: authelia-redis
          password: ''\${AUTHELIA_REDIS_PASSWORD}
          port: 6379

      regulation:
        max_retries: 3
        find_time: 10m
        ban_time: 15m

      storage:
        encryption_key: ''\${AUTHELIA_STORAGE_ENCRYPTION_KEY}
        local:
          path: /config/db.sqlite3

      notifier:
        filesystem:
          filename: /config/notification.txt

      webauthn:
        disable: false
        display_name: ${config.base_domain}
        attestation_conveyance_preference: indirect
        timeout: 60s

      totp:
        issuer: ${config.base_domain}
        period: 30
        skew: 1

      identity_providers:
        oidc:
          hmac_secret: ''\${AUTHELIA_OIDC_HMAC_SECRET}
          lifespans:
            access_token: 8760h
            refresh_token: 8760h
          jwks:
            - key_id: main
              algorithm: RS256
              use: sig
              key_file: /config/oidc_jwks.pem
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_NPM_SECRET}
              public: false
              authorization_policy: two_factor
              redirect_uris:
                - https://proxy.${config.base_domain}/oauth2/callback
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_NOCODB_SECRET}
              public: false
              authorization_policy: two_factor
              redirect_uris:
                - https://db.${config.base_domain}/api/v1/auth/oidc/callback
                - https://db.${config.base_domain}/api/v2/auth/oidc/callback
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLI_SECRET}
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
                - https://photos.app.diegonmarcos.com/
                - https://proxy.diegonmarcos.com/
                - https://rss.diegonmarcos.com/
                - https://sync.diegonmarcos.com/
                - https://vault.diegonmarcos.com/
    '';

    # Users database template (hash comes from .env via envsubst)
    mkUsersDatabase = pkgs: pkgs.writeText "users_database.yml.tpl" ''
      ---
      users:
        diego:
          displayname: "Diego"
          password: "''\${AUTHELIA_USER_DIEGO_HASH}"
          email: diego@diegonmarcos.com
          groups:
            - admins
            - users
    '';

    # Init script: envsubst templates → final configs, then start authelia
    mkInitScript = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e

      CONFIG_VARS='$AUTHELIA_JWT_SECRET $AUTHELIA_SESSION_SECRET $AUTHELIA_STORAGE_ENCRYPTION_KEY $AUTHELIA_REDIS_PASSWORD $AUTHELIA_OIDC_HMAC_SECRET $AUTHELIA_OIDC_CLIENT_CLI_SECRET $AUTHELIA_OIDC_CLIENT_NPM_SECRET $AUTHELIA_OIDC_CLIENT_NOCODB_SECRET'
      USER_VARS='$AUTHELIA_USER_DIEGO_HASH'

      echo "[init] Substituting secrets into configuration..."
      envsubst "$CONFIG_VARS" < /config/configuration.yml.tpl > /config/configuration.yml
      envsubst "$USER_VARS" < /config/users_database.yml.tpl > /config/users_database.yml

      # Write OIDC JWKS key file if env var is set
      if [ -n "$AUTHELIA_OIDC_JWKS_KEY" ]; then
        echo "[init] Writing OIDC JWKS key..."
        printf '%s\n' "$AUTHELIA_OIDC_JWKS_KEY" > /config/oidc_jwks.pem
        chmod 600 /config/oidc_jwks.pem
      fi

      echo "[init] Starting Authelia..."
      exec authelia --config /config/configuration.yml
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "authelia-configs" {} ''
        mkdir -p $out/config
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkAutheliaConfig pkgs} $out/config/configuration.yml.tpl
        cp ${mkUsersDatabase pkgs} $out/config/users_database.yml.tpl
        cp ${mkInitScript pkgs} $out/config/init.sh
        chmod +x $out/config/init.sh
      '';
    });
  };
}
