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
      image = "authelia/authelia:4.39.15";
      port = 9091;
      timezone = "Europe/Madrid";
    };

    title = "Authelia 2FA Authentication";

    # Generate docker-compose.yml (authelia + redis)
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bb-sec_authelia/src/flake.nix   ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bb-sec_authelia/build.sh ship  ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        authelia:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            TZ: ${config.timezone}
          volumes:
            - ./config:/config
          entrypoint: ["sh", "/config/init.sh"]
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
          env_file:
            - .secrets
          command: sh -c 'redis-server --requirepass $$AUTHELIA_REDIS_PASSWORD'
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
        disable_startup_check: true
        smtp:
          address: submissions://10.0.0.3:465
          username: no-reply@diegonmarcos.com
          password: ''\${AUTHELIA_SMTP_PASSWORD}
          sender: "Authelia <no-reply@diegonmarcos.com>"
          tls:
            server_name: smtp.diegonmarcos.com

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
                - https://photos.diegonmarcos.com/
                - https://proxy.diegonmarcos.com/
                - https://rss.diegonmarcos.com/
                - https://sync.diegonmarcos.com/
                - https://vault.diegonmarcos.com/
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
        AUTHELIA_OIDC_CLIENT_DAGU_SECRET \
        AUTHELIA_OIDC_CLIENT_MONITORING_SECRET \
        AUTHELIA_OIDC_CLIENT_MATTERMOST_SECRET \
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

    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) concatMapStrings hasSuffix optionalString filter subtractLists removeSuffix;
      inherit (builtins) attrNames readDir pathExists;

      portKeys = filter (k: hasSuffix "_port" k || k == "port") (attrNames config);
      imageKeys = filter (k: hasSuffix "_image" k || k == "image") (attrNames config);
      containerKeys = filter (k: hasSuffix "_container" k || k == "container_name") (attrNames config);
      domainKeys = filter (k: k == "domain" || k == "base_domain") (attrNames config);
      otherKeys = subtractLists (portKeys ++ imageKeys ++ containerKeys ++ domainKeys) (attrNames config);

      row = k: let
        v = config.${k};
        vs = if builtins.isBool v then (if v then "true" else "false")
             else if builtins.isAttrs v || builtins.isList v then builtins.toJSON v
             else toString v;
      in "| `${k}` | `${vs}` |\n";
      section = heading: keys: optionalString (keys != []) ''
        ## ${heading}
        | Key | Value |
        |-----|-------|
        ${concatMapStrings row keys}
      '';

      hasNarrative = pathExists ./docs;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir ./docs))
        else [];

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
      '';

      summaryMd = pkgs.writeText "SUMMARY.md" ''
        # Summary
        - [Specification](./spec.md)
        - [Generated Configs](./configs.md)
        ${concatMapStrings (f: "- [${removeSuffix ".md" f}](./${f})\n") narrativeFiles}
      '';

      bookToml = pkgs.writeText "book.toml" ''
        [book]
        title = "${title}"
        [output.html]
        default-theme = "ayu"
      '';
    in pkgs.runCommand "docs" {
      nativeBuildInputs = [ pkgs.mdbook pkgs.file ];
    } ''
      mkdir -p build/src
      cp ${bookToml} build/book.toml
      cp ${summaryMd} build/src/SUMMARY.md
      cp ${specMd} build/src/spec.md
      ${optionalString hasNarrative "cp ${./docs}/*.md build/src/ 2>/dev/null || true"}

      # Generate configs.md from packages.default output
      echo "# Generated Configuration Files" > build/src/configs.md
      echo "" >> build/src/configs.md
      echo 'These files are produced by nix build and deployed to the VM.' >> build/src/configs.md
      echo "" >> build/src/configs.md
      find ${defaultPkg} -type f | sort | while read -r f; do
        relpath="''${f#${defaultPkg}/}"
        case "$relpath" in
          .secrets|*.secrets|*.lock|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.eot) continue ;;
        esac
        case "$relpath" in
          *.yml|*.yaml)   lang="yaml" ;;
          *.json)         lang="json" ;;
          *.toml)         lang="toml" ;;
          *.py)           lang="python" ;;
          *.sh)           lang="bash" ;;
          *.js|*.ts)      lang="javascript" ;;
          *.tf)           lang="hcl" ;;
          *.conf|*.cnf)   lang="ini" ;;
          *.html)         lang="html" ;;
          *.sql)          lang="sql" ;;
          *.zone)         lang="dns" ;;
          Dockerfile*)    lang="dockerfile" ;;
          Caddyfile*)     lang="caddy" ;;
          *)              lang="" ;;
        esac
        if file -b --mime-type "$f" | grep -q "^text/"; then
          echo '## '"$relpath" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo "~~~$lang" >> build/src/configs.md
          cat "$f" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo '~~~' >> build/src/configs.md
          echo "" >> build/src/configs.md
        fi
      done

      cd build && mdbook build -d $out
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
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
