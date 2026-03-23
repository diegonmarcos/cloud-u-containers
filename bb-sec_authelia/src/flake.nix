{
  description = "Authelia 2FA Authentication - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      domain = buildJson.domain;
      base_domain = "diegonmarcos.com";
      container_name = "authelia";
      image = "authelia/authelia:4.39.15";
      port = buildJson.ports.app;
      redis_port = toString buildJson.ports.redis;
      timezone = "Europe/Madrid";
    };

    title = "Authelia 2FA Authentication";
    docker = import ../../_shared/docker.nix;

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

    # Generate YAML rules — indentation relative to the rules: key in the template
    # The template has `rules:\n${accessControlYaml}` at 6-space indent
    mkResourceLines = resources:
      lib.concatMapStringsSep "\n" (r: "          - \"${r}\"") resources;

    mkRuleYaml = rule:
      let
        hasBypass = rule ? resources_bypass && rule.resources_bypass != [];
        hasTwoFactor = rule ? resources_two_factor && rule.resources_two_factor != [];
        plainRule =
          if !hasBypass && !hasTwoFactor then ''
          - domain: '${rule.domain}'
            policy: ${rule.policy}''
          else "";
        bypassRule =
          if hasBypass then ''
          - domain: '${rule.domain}'
            resources:
${mkResourceLines rule.resources_bypass}
            policy: bypass''
          else "";
        twoFactorRule =
          if hasTwoFactor then ''
          - domain: '${rule.domain}'
            resources:
${mkResourceLines rule.resources_two_factor}
            policy: two_factor''
          else "";
        baseRule =
          if hasBypass && rule ? policy && rule.policy != "" then ''
          - domain: '${rule.domain}'
            policy: ${rule.policy}''
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
          image = config.image;
          container_name = config.container_name;
          entrypoint = ["sh" "/config/init.sh"];
          env_file = [".secrets"];
          environment = { TZ = config.timezone; };
          volumes = ["./config:/config"];
          ports = ["10.0.0.1:${toString config.port}:9091"];
          networks = ["auth-net"];
          depends_on = { redis = {}; };
          skipReadOnly = true;
          capAdd = ["DAC_OVERRIDE"];
        };
        redis = docker.mkService {
          name = "redis";
          image = "redis:7-bookworm";
          container_name = "authelia-redis";
          env_file = [".secrets"];
          command = "sh -c 'redis-server --port ${config.redis_port} --requirepass $$AUTHELIA_REDIS_PASSWORD --appendonly yes --appendfsync everysec --save 900 1 --save 300 10'";
          volumes = ["authelia_redis_data:/data"];
          networks = ["auth-net"];
          skipReadOnly = true;
        };
      };
      volumes = {
        authelia_redis_data = {};
      };
      networks = {
        auth-net = { driver = "bridge"; };
      };
    };

    # Generate authelia configuration.yml template
    # Secrets use ''${VAR} placeholders, substituted by init.sh via envsubst
    mkAutheliaConfig = pkgs: pkgs.writeText "configuration.yml.tpl" ''
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
          host: localhost
          password: ''\${AUTHELIA_REDIS_PASSWORD}
          port: ${config.redis_port}

      regulation:
        max_retries: 3
        find_time: 10m
        ban_time: 15m

      storage:
        encryption_key: ''\${AUTHELIA_STORAGE_ENCRYPTION_KEY}
        local:
          path: /config/db.sqlite3

      notifier:
        disable_startup_check: true
        smtp:
          address: submissions://10.0.0.3:465
          username: no-reply@diegonmarcos.com
          password: ''\${AUTHELIA_SMTP_PASSWORD}
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
          hmac_secret: ''\${AUTHELIA_OIDC_HMAC_SECRET}
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

            - client_id: cloudflare-health-c3-api
              consent_mode: explicit
              client_name: Cloudflare Worker Health Check
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_DAGU_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_MONITORING_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET}
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
              client_secret: ''\${AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET}
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
                - https://*.diegonmarcos.com/
                - https://diegonmarcos.com/
    '';

    # Users database template (hash comes from .env via envsubst)
    mkUsersDatabase = pkgs: pkgs.writeText "users_database.yml.tpl" ''
      ---
      users:
        me@diegonmarcos.com:
          displayname: "Diego"
          password: "''\${AUTHELIA_USER_DIEGO_HASH}"
          email: me@diegonmarcos.com
          groups:
            - admins
            - users
    '';

    # Init script: envsubst templates → final configs, then start authelia
    mkInitScript = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e

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

      echo "[init] Substituting secrets into configuration..."
      cp /config/configuration.yml.tpl /config/configuration.yml
      subst /config/configuration.yml \
        AUTHELIA_JWT_SECRET \
        AUTHELIA_SESSION_SECRET \
        AUTHELIA_STORAGE_ENCRYPTION_KEY \
        AUTHELIA_REDIS_PASSWORD \
        AUTHELIA_OIDC_HMAC_SECRET \
        AUTHELIA_OIDC_CLIENT_CLI_SECRET \
        AUTHELIA_OIDC_CLIENT_CLOUDFLARE_SECRET \
        AUTHELIA_OIDC_CLIENT_CLAUDE_SECRET \
        AUTHELIA_OIDC_CLIENT_CLOUD_ADMIN_SECRET \
        AUTHELIA_OIDC_CLIENT_CLAUDE_OPUS_SECRET \
        AUTHELIA_OIDC_CLIENT_CLAUDE_SONNET_SECRET \
        AUTHELIA_OIDC_CLIENT_CLAUDE_HAIKU_SECRET \
        AUTHELIA_OIDC_CLIENT_DAGU_SECRET \
        AUTHELIA_OIDC_CLIENT_MONITORING_SECRET \
        AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET \
        AUTHELIA_OIDC_CLIENT_DAGU_CC_SECRET \
        AUTHELIA_OIDC_CLIENT_MATTERMOST_CC_SECRET \
        AUTHELIA_OIDC_CLIENT_C3_MCP_SECRET \
        AUTHELIA_OIDC_CLIENT_NPM_SECRET \
        AUTHELIA_OIDC_CLIENT_NOCODB_SECRET \
        AUTHELIA_SMTP_PASSWORD

      cp /config/users_database.yml.tpl /config/users_database.yml
      subst /config/users_database.yml AUTHELIA_USER_DIEGO_HASH

      # Inject JWKS private key into configuration
      if [ -f /config/oidc_jwks.pem ]; then
        echo "[init] Injecting OIDC JWKS key into configuration..."
        awk '
          /key: __JWKS_KEY__/ {
            match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
            print ind "key: |"
            while ((getline line < "/config/oidc_jwks.pem") > 0)
              print ind "  " line
            next
          }
          { print }
        ' /config/configuration.yml > /config/configuration.yml.tmp
        mv /config/configuration.yml.tmp /config/configuration.yml
      fi

      echo "[init] Starting Authelia..."
      exec authelia --config /config/configuration.yml
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      defaultPkg = pkgs.runCommand "authelia-configs" {} ''
        mkdir -p $out/config
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkAutheliaConfig pkgs} $out/config/configuration.yml.tpl
        cp ${mkUsersDatabase pkgs} $out/config/users_database.yml.tpl
        cp ${mkInitScript pkgs} $out/config/init.sh
        chmod +x $out/config/init.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; docsPath = ./docs; };
    });
  };
}
