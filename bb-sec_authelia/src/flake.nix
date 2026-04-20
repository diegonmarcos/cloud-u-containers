{
  description = "Authelia 2FA Authentication - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-authelia.json (symlink → I_cloud-data/
    # build-authelia.json). Engine resolves symlink before nix build.
    buildAuthelia = builtins.fromJSON (builtins.readFile ./build-authelia.json);
    svc = buildAuthelia.services;

    config = {
      domain = buildJson.domain;
      base_domain = "diegonmarcos.com";
      container_name = "authelia";
      image = ghcr.image;
      port = buildJson.ports.app;
      redis_port = toString buildJson.ports.redis;
      timezone = "Europe/Madrid";
    };

    title = "Authelia 2FA Authentication";
    docker = import ../../_shared/docker.nix;

    # GHCR image: bake config + init script into image
    # init.sh maps env var names to Authelia-native names, then exec authelia
    ghcr = docker.mkGhcrBuild {
      name = "authelia";
      fromImage = "authelia/authelia:4.39.15";
      configFiles = [
        { src = "config/configuration.yml"; dst = "/config/configuration.yml"; }
        { src = "config/init.sh"; dst = "/config/init.sh"; }
      ];
    };

    # ACL rules from build-authelia.json (buildAuthelia.acl). Falls back to a
    # minimal default if no rules are declared.
    autheliaAcl =
      if buildAuthelia.acl.rules == []
      then { rules = [{ domain = "*.diegonmarcos.com"; policy = "two_factor"; service = "_default"; }]; }
      else buildAuthelia.acl;

    # Generate YAML access_control rules from the JSON structure
    # Each rule can have: domain, policy, resources_bypass, resources_two_factor
    # A rule with resources_bypass produces a bypass rule with those resources
    # A rule with resources_two_factor produces a two_factor rule with those resources
    # A plain rule (no resources_*) produces a single rule with domain+policy
    lib = nixpkgs.lib;

    # Generate YAML rules with exact indentation for the output YAML
    # Rules appear under `rules:` at 6-space indent in the final config
    ind = "    ";  # 4 spaces for list items under access_control.rules
    ind2 = "      ";  # 6 spaces for properties
    ind3 = "        ";  # 8 spaces for nested lists

    mkResourceLines = resources:
      lib.concatMapStringsSep "\n" (r: "${ind3}- \"${r}\"") resources;

    mkRuleYaml = rule:
      let
        hasBypass = rule ? resources_bypass && rule.resources_bypass != [];
        hasTwoFactor = rule ? resources_two_factor && rule.resources_two_factor != [];
        plainRule =
          if !hasBypass && !hasTwoFactor
          then "${ind}- domain: '${rule.domain}'\n${ind2}policy: ${rule.policy}"
          else "";
        bypassRule =
          if hasBypass
          then "${ind}- domain: '${rule.domain}'\n${ind2}resources:\n${mkResourceLines rule.resources_bypass}\n${ind2}policy: bypass"
          else "";
        twoFactorRule =
          if hasTwoFactor
          then "${ind}- domain: '${rule.domain}'\n${ind2}resources:\n${mkResourceLines rule.resources_two_factor}\n${ind2}policy: two_factor"
          else "";
        baseRule =
          if hasBypass && rule ? policy && rule.policy != ""
          then "${ind}- domain: '${rule.domain}'\n${ind2}policy: ${rule.policy}"
          else "";
        parts = builtins.filter (s: s != "") [ bypassRule twoFactorRule baseRule plainRule ];
      in lib.concatStringsSep "\n" parts;

    accessControlYaml =
      lib.concatStringsSep "\n" (map mkRuleYaml autheliaAcl.rules);

    # Generate docker-compose.yml (authelia + redis)
    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bb-sec_authelia/src/flake.nix";
      services = {
        authelia = docker.mkService {
          name = "authelia";
          image = ghcr.image;
          build = ghcr.build;
          container_name = config.container_name;
          networkMode = null;  # bridge mode — port mapping binds to WG IP only
          entrypoint = ["sh" "/config/init.sh"];
          env_file = [".secrets"];
          environment = {
            TZ = config.timezone;
            X_AUTHELIA_CONFIG_FILTERS = "template";
          };
          volumes = [
            "authelia_data:/data"
            "./config/oidc_jwks.pem:/config/oidc_jwks.pem:ro"
            "./.secrets.d:/config/.secrets.d:ro"
          ];
          ports = ["${svc.authelia.ip}:${toString config.port}:9091"];
          networks = ["auth-net"];
          depends_on = { redis = {}; };
          skipReadOnly = true;
          capAdd = ["DAC_OVERRIDE"];
          memLimit = "128M";
          memReservation = "32M";
        };
        redis = docker.mkService {
          name = "redis";
          image = "ghcr.io/diegonmarcos/redis:latest";
          container_name = "authelia-redis";
          networkMode = null;  # bridge mode — isolated in auth-net
          env_file = [".secrets"];
          command = "sh -c 'redis-server --port ${config.redis_port} --requirepass $$AUTHELIA_REDIS_PASSWORD --appendonly yes --appendfsync everysec --save 900 1 --save 300 10'";
          volumes = ["authelia_redis_data:/data"];
          networks = ["auth-net"];
          skipReadOnly = true;
          memLimit = "48M";
          memReservation = "16M";
        };
      };
      volumes = {
        authelia_redis_data = {};
        authelia_data = {};
      };
      networks = {
        auth-net = { driver = "bridge"; };
      };
    };

    # Generate authelia configuration.yml (final config — no secret placeholders)
    # All secrets are provided via Authelia-native env vars (mapped by init.sh)
    mkAutheliaConfig = pkgs: pkgs.writeText "configuration.yml" ''
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
        - domain: ${config.domain}
          policy: bypass
    ${accessControlYaml}
        - domain: "*.${config.base_domain}"
          policy: two_factor

    identity_validation:
      reset_password:
        jwt_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_JWT_SECRET" }}'

    session:
      secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_SESSION_SECRET" }}'
      name: authelia_session
      cookies:
        - name: authelia_session
          domain: ${config.base_domain}
          authelia_url: https://${config.domain}
          inactivity: 5m
          expiration: 1h
          remember_me: 30d
      redis:
        host: redis
        port: ${config.redis_port}
        password: '{{ secret "/tmp/.secrets.d/AUTHELIA_REDIS_PASSWORD" }}'

    regulation:
      max_retries: 3
      find_time: 10m
      ban_time: 15m

    storage:
      encryption_key: '{{ secret "/tmp/.secrets.d/AUTHELIA_STORAGE_ENCRYPTION_KEY" }}'
      local:
        path: /data/db.sqlite3

    notifier:
      disable_startup_check: true
      smtp:
        address: submissions://${svc.maddy.ip}:${toString svc.maddy.ports.smtp}
        username: no-reply@diegonmarcos.com
        password: '{{ secret "/tmp/.secrets.d/AUTHELIA_SMTP_PASSWORD" }}'
        sender: "Authelia <no-reply@diegonmarcos.com>"
        tls:
          server_name: mail.diegonmarcos.com

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
        hmac_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_HMAC_SECRET" }}'
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
          - client_id: oauth2-proxy-npm
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_NPM_SECRET" }}'
            consent_mode: explicit
            client_name: NPM Proxy Manager
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_NOCODB_SECRET" }}'
            consent_mode: explicit
            client_name: NocoDB Database
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

          - client_id: cloudflare-health-c3-api
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET" }}'
            consent_mode: explicit
            client_name: Cloudflare Worker Health Check
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET" }}'
            consent_mode: explicit
            client_name: Claude AI Agent
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET" }}'
            consent_mode: explicit
            client_name: Cloud Admin
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET" }}'
            consent_mode: explicit
            client_name: Claude Opus Agent
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET" }}'
            consent_mode: explicit
            client_name: Claude Sonnet Agent
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET" }}'
            consent_mode: explicit
            client_name: Claude Haiku Agent
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_DAGU_SECRET" }}'
            consent_mode: explicit
            client_name: Dagu Workflow Engine
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET" }}'
            client_name: Dagu Service Account
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_MONITORING_SECRET" }}'
            consent_mode: explicit
            client_name: Monitoring Read-Only
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET" }}'
            consent_mode: explicit
            client_name: Mattermost Bot
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET" }}'
            client_name: Mattermost Service Account
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET" }}'
            client_name: C3 Infra MCP API
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
            client_secret: '{{ secret "/tmp/.secrets.d/AUTHELIA_OIDC_CLIENT_CLI_SECRET" }}'
            consent_mode: explicit
            client_name: CLI Access
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
    '';

    # Users database generated at runtime by init.sh from AUTHELIA_USER_DIEGO_HASH env var
    # (hash stays in sops-encrypted secrets.yaml, never in source)

    # Init script: map custom env var names → Authelia-native env var names, then exec
    # No awk/grep/sed — secrets flow via env file + native env var support
    mkInitScript = pkgs: pkgs.writeText "init.sh" ''
    #!/bin/sh
    set -e

    echo "[init] Writing secrets to files for {{ secret }} template..."

    # Write each env var to a file — {{ secret "/path" }} reads raw bytes (safe for $)
    mkdir -p /tmp/.secrets.d
    for var in \
      AUTHELIA_JWT_SECRET \
      AUTHELIA_SESSION_SECRET \
      AUTHELIA_STORAGE_ENCRYPTION_KEY \
      AUTHELIA_REDIS_PASSWORD \
      AUTHELIA_SMTP_PASSWORD \
      AUTHELIA_OIDC_HMAC_SECRET \
      AUTHELIA_OIDC_CLIENT_NPM_SECRET \
      AUTHELIA_OIDC_CLIENT_NOCODB_SECRET \
      AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET \
      AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET \
      AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET \
      AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET \
      AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET \
      AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET \
      AUTHELIA_OIDC_CLIENT_DAGU_SECRET \
      AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET \
      AUTHELIA_OIDC_CLIENT_MONITORING_SECRET \
      AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET \
      AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET \
      AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET \
      AUTHELIA_OIDC_CLIENT_CLI_SECRET; do
      eval "val=\$$var"
      printf '%s' "$val" > "/tmp/.secrets.d/$var"
    done

    echo "[init] Generating users database..."

    # Users database (heredoc safe for $ in Argon2 hashes)
    cat > /tmp/users_database.yml <<USERDB
    ---
    users:
      me@diegonmarcos.com:
        displayname: "Diego"
        password: "$AUTHELIA_USER_DIEGO_HASH"
        email: me@diegonmarcos.com
        groups:
          - admins
          - users
    USERDB

    # JWKS key: generate a YAML overlay with the PEM properly indented
    # Authelia merges multiple --config files; this avoids template multiline issues
    echo "[init] Generating JWKS overlay..."
    cat > /tmp/jwks-overlay.yml <<'JWKSEOF'
    identity_providers:
      oidc:
        jwks:
          - key_id: main
            algorithm: RS256
            use: sig
            key: |
    JWKSEOF
    sed 's/^/              /' /config/oidc_jwks.pem >> /tmp/jwks-overlay.yml

    echo "[init] Starting Authelia..."
    exec authelia \
      --config /config/configuration.yml \
      --config /tmp/jwks-overlay.yml \
      --config.experimental.filters template
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      defaultPkg = pkgs.runCommand "authelia-configs" {} ''
        mkdir -p $out/config
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkAutheliaConfig pkgs} $out/config/configuration.yml
        cp ${mkInitScript pkgs} $out/config/init.sh
        chmod +x $out/config/init.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; docsPath = ./docs; };
    });
  };
}
