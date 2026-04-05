{
  description = "Authelia 2FA Authentication - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;

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

    # ACL rules from external JSON (cloud-data-authelia-acl.json)
    # Falls back to a minimal default if the file doesn't exist
    autheliaAcl =
      if builtins.pathExists ./cloud-data-authelia-acl.json
      then builtins.fromJSON (builtins.readFile ./cloud-data-authelia-acl.json)
      else { rules = [{ domain = "*.diegonmarcos.com"; policy = "two_factor"; service = "_default"; }]; };

    # Generate YAML access_control rules from the JSON structure
    # Each rule can have: domain, policy, resources_bypass, resources_two_factor
    # A rule with resources_bypass produces a bypass rule with those resources
    # A rule with resources_two_factor produces a two_factor rule with those resources
    # A plain rule (no resources_*) produces a single rule with domain+policy
    lib = nixpkgs.lib;

    # Generate YAML rules with exact indentation for the output YAML
    # Rules appear under `rules:` at 6-space indent in the final config
    ind = "      ";  # 6 spaces for list items
    ind2 = "        ";  # 8 spaces for properties
    ind3 = "          ";  # 10 spaces for nested lists

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
          entrypoint = ["sh" "/config/init.sh"];
          environment = { TZ = config.timezone; };
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
          path: /config/users_database.yml
          watch: true

      access_control:
        default_policy: two_factor
        rules:
          - domain: ${config.domain}
            policy: bypass
    ${accessControlYaml}
          - domain: "*.${config.base_domain}"
            policy: two_factor

      session:
        name: authelia_session
        cookies:
          - name: authelia_session
            domain: ${config.base_domain}
            authelia_url: https://${config.domain}
            inactivity: 5m
            expiration: 1h
            remember_me: 30d
        redis:
          host: localhost
          port: ${config.redis_port}

      regulation:
        max_retries: 3
        find_time: 10m
        ban_time: 15m

      storage:
        local:
          path: /data/db.sqlite3

      notifier:
        disable_startup_check: true
        smtp:
          address: submissions://${svc.stalwart.ip}:${toString svc.stalwart.ports.smtp}
          username: no-reply@diegonmarcos.com
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
          lifespans:
            access_token: 87600h
            refresh_token: 87600h
          jwks:
            - key_id: main
              algorithm: RS256
              use: sig
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

<<<<<<< Updated upstream
      # Replace ''${VAR} placeholders with env values using awk (literal string, no regex)
      # Usage: subst <file> VAR1 VAR2 ...
      subst() {
        _file="$1"; shift
        for _var in "$@"; do
          _val=$(cat "/config/.secrets.d/$_var")
          awk -v pat="\''${''${_var}}" -v rep="$_val" '{
            while (i = index($0, pat)) {
              $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
            }
            print
          }' "$_file" > "$_file.tmp"
          mv "$_file.tmp" "$_file"
        done
      }
||||||| Stash base
      # Replace ''${VAR} placeholders with env values using awk (literal string, no regex)
      # Usage: subst <file> VAR1 VAR2 ...
      subst() {
        _file="$1"; shift
        for _var in "$@"; do
          eval _val="\$$_var"
          awk -v pat="\''${''${_var}}" -v rep="$_val" '{
            while (i = index($0, pat)) {
              $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
            }
            print
          }' "$_file" > "$_file.tmp"
          mv "$_file.tmp" "$_file"
        done
      }
=======
      echo "[init] Mapping env vars to Authelia-native names..."
>>>>>>> Stashed changes

      # Standard secrets (custom name → Authelia native path)
      export AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="$AUTHELIA_JWT_SECRET"
      export AUTHELIA_SESSION_REDIS_PASSWORD="$AUTHELIA_REDIS_PASSWORD"
      export AUTHELIA_NOTIFIER_SMTP_PASSWORD="$AUTHELIA_SMTP_PASSWORD"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="$AUTHELIA_OIDC_HMAC_SECRET"

      # OIDC client secrets (index matches client order in configuration.yml)
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_NPM_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_1_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_NOCODB_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_2_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_3_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_4_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_5_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_6_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_7_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_8_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_DAGU_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_9_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_10_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_MONITORING_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_11_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_12_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_13_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET"
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_14_CLIENT_SECRET="$AUTHELIA_OIDC_CLIENT_CLI_SECRET"

      # JWKS key from mounted file (Authelia reads PEM content via _FILE suffix)
      export AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY_FILE="/config/oidc_jwks.pem"

      # AUTHELIA_SESSION_SECRET, AUTHELIA_STORAGE_ENCRYPTION_KEY already match native names

      # Generate users database from sops-delivered env var (heredoc is single-pass, safe for $)
      cat > /config/users_database.yml <<USERDB
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

      echo "[init] Starting Authelia..."
      exec authelia --config /config/configuration.yml
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
