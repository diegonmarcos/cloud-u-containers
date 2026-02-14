{
  description = "Caddy - Declarative reverse proxy with automatic HTTPS (replaces NPM on gcp-proxy + oci-mail)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "caddy";
      http_port = 80;
      https_port = 443;
      admin_port = 2019;
    };

    # WireGuard IPs
    gcp = "10.0.0.1";       # gcp-proxy
    flex = "10.0.0.2";      # oci-flex (on-demand)
    mail = "10.0.0.3";      # oci-mail
    analytics = "10.0.0.4"; # oci-analytics

    # ── Security snippets ─────────────────────────────────────────

    # 1. Security headers (HSTS, anti-clickjacking, etc.)
    securityHeaders = ''
      (security_headers) {
        header {
          Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
          X-Content-Type-Options "nosniff"
          X-Frame-Options "SAMEORIGIN"
          Referrer-Policy "strict-origin-when-cross-origin"
          Permissions-Policy "camera=(), microphone=(), geolocation=()"
          -Server
        }
      }
    '';

    # 2. Rate limiting (100 req/min per IP — requires caddy-ratelimit plugin)
    rateLimiting = ''
      (rate_limiting) {
        rate_limit {
          zone global {
            key    {remote_host}
            events 100
            window 1m
          }
        }
      }
    '';

    # 3. Bot blocking (known malicious scanners only)
    blockBots = ''
      (block_bots) {
        @bad_bots header_regexp User-Agent "(?i)(sqlmap|nikto|masscan|nmap|zgrab|scrapy|dirbuster|gobuster|nuclei|wfuzz|havij|acunetix|nessus|openvas)"
        respond @bad_bots 403
      }
    '';

    # 4. Scanner path blocking (common exploit paths)
    blockScanners = ''
      (block_scanners) {
        @blocked_paths path /wp-admin* /wp-login* /xmlrpc.php /.env /.git* /phpmyadmin* /actuator* /solr* /console* /.aws* /cgi-bin/*
        respond @blocked_paths 404
      }
    '';

    # 5. Request size limits (10MB default)
    requestLimits = ''
      (request_limits) {
        request_body {
          max_size 10MB
        }
      }
    '';

    # 6. IP blocking (placeholder — ready to activate)
    ipBlock = ''
      (ip_block) {
        # @blocked_ips remote_ip 192.0.2.0/24
        # respond @blocked_ips 403
      }
    '';

    # 7. Access logging (JSON to mounted volume for fail2ban)
    accessLog = ''
      (access_log) {
        log {
          output file /var/log/caddy/access.log {
            roll_size 10mb
            roll_keep 5
          }
          format json
        }
      }
    '';

    # Combined security snippet (imports all layers)
    securitySnippet = ''
      (security) {
        import security_headers
        import block_bots
        import block_scanners
        import rate_limiting
        import ip_block
        import access_log
      }
    '';

    # Per-site imports: sec = full security + size limit, secNoLimit = security only
    sec = ''
        import security
        import request_limits'';

    secNoLimit = ''
        import security'';

    # ── Auth snippets ────────────────────────────────────────────
    # Authelia forward_auth (cookie-based, for browser sessions)
    authelia = ''
        forward_auth authelia:9091 {
          uri /api/authz/forward-auth
          copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        }'';

    # Bearer token auth via introspect-proxy sidecar (OIDC token introspection)
    bearer = ''
        forward_auth introspect-proxy:4182 {
          uri /auth
          copy_headers X-Auth-User X-Auth-Subject X-Auth-Email
        }'';

    # Site-level error handler for connection failures AND HTTP errors
    handleErrors = ''
      handle_errors {
        @backend_error expression `{err.status_code} == 502 || {err.status_code} == 503 || {err.status_code} == 504`
        handle @backend_error {
          root * /srv
          rewrite * /error.html
          file_server
        }
      }'';

    # Reusable protected block: bearer token → introspect-proxy, cookie → authelia
    mkProtected = upstream: ''
      @bearer header Authorization Bearer*
      handle @bearer {
    ${bearer}
        reverse_proxy ${upstream}
      }
      handle {
    ${authelia}
        reverse_proxy ${upstream}
      }
    '';

    # GitHub Pages reverse proxy (keeps subdomain URL in browser)
    mkGithubProxy = path: ''
      rewrite * /${path}{uri}
      reverse_proxy https://diegonmarcos.github.io {
        header_up Host diegonmarcos.github.io
      }
    '';

    # Same but with custom reverse_proxy block (for tls_insecure_skip_verify etc.)
    mkProtectedCustom = upstreamUrl: transportBlock: ''
      @bearer header Authorization Bearer*
      handle @bearer {
    ${bearer}
        reverse_proxy ${upstreamUrl} {
          ${transportBlock}
        }
      }
      handle {
    ${authelia}
        reverse_proxy ${upstreamUrl} {
          ${transportBlock}
        }
      }
    '';

    mkCaddyfile = pkgs: pkgs.writeText "Caddyfile" ''
      {
        admin localhost:${toString config.admin_port}
        order respond before handle
      }

      # ════════════════════════════════════════════════════════════
      # SECURITY SNIPPETS
      # ════════════════════════════════════════════════════════════

      ${securityHeaders}
      ${rateLimiting}
      ${blockBots}
      ${blockScanners}
      ${requestLimits}
      ${ipBlock}
      ${accessLog}
      ${securitySnippet}

      # ════════════════════════════════════════════════════════════
      # PUBLIC / BYPASS (no auth)
      # ════════════════════════════════════════════════════════════

      # Authelia itself — must be public (bypass policy in Authelia config)
      auth.diegonmarcos.com {
    ${sec}
        reverse_proxy authelia:9091
        ${handleErrors}
      }

      # API — Flask + Rust backends
      api.diegonmarcos.com {
    ${sec}
        handle /rust/* {
          reverse_proxy ${gcp}:8080
        }
        handle {
          reverse_proxy ${gcp}:5000
        }
        ${handleErrors}
      }

      # Radicale CalDAV/CardDAV
      cal.diegonmarcos.com {
    ${sec}
        reverse_proxy ${flex}:5232
        ${handleErrors}
      }

      # Affine collaborative docs (100MB uploads, long timeouts)
      drive-notes-affine.diegonmarcos.com {
    ${secNoLimit}
        request_body {
          max_size 100MB
        }
        reverse_proxy ${flex}:3010 {
          transport http {
            read_timeout 3600s
            write_timeout 3600s
          }
        }
        ${handleErrors}
      }

      # ── GitHub Pages reverse proxies (URL stays as subdomain) ──

      # Landing page
      diegonmarcos.com, www.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "landpage"}
        ${handleErrors}
      }

      # Linktree
      linktree.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "linktree"}
        ${handleErrors}
      }

      # Cloud dashboard
      cloud.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "cloud"}
        ${handleErrors}
      }

      # Nexus
      nexus.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "nexus"}
        ${handleErrors}
      }

      # Suite apps dashboard
      suite.diegonmarcos.com {
    ${sec}
        ${mkGithubProxy "suite"}
        ${handleErrors}
      }

      # ════════════════════════════════════════════════════════════
      # ANALYTICS — Matomo (public tracking + protected admin)
      # ════════════════════════════════════════════════════════════

      analytics.diegonmarcos.com {
    ${sec}
        # Public tracking endpoints (no auth — called by portfolio sites)
        @tracking {
          path /matomo.js /matomo.php /piwik.js /piwik.php /collect.php /api.php /track.php
          path /js/*
        }
        handle @tracking {
          reverse_proxy ${analytics}:8080
        }

        # Protected admin dashboard
        ${mkProtected "${analytics}:8080"}

        ${handleErrors}
      }

      # ════════════════════════════════════════════════════════════
      # AUTHELIA-PROTECTED (bearer token bypass for CLI/API)
      # ════════════════════════════════════════════════════════════

      # PhotoPrism
      photos.diegonmarcos.com {
    ${sec}
        # Root path → landing page (replaces Cloudflare redirect rule)
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/myphotos/ permanent
        }

        # All other paths → auth + PhotoPrism
        ${mkProtected "${flex}:3013"}
        ${handleErrors}
      }

      # Syncthing
      sync.diegonmarcos.com {
    ${sec}
        ${mkProtected "${mail}:8384"}
        ${handleErrors}
      }

      # Mailu webmail (upstream is HTTPS with self-signed cert)
      mail.diegonmarcos.com {
    ${sec}
        # Root path → landing page (replaces Cloudflare redirect rule)
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/mymail/ permanent
        }

        # All other paths → auth + Mailu
        ${mkProtectedCustom "https://${mail}:8444" ''
          transport http {
            tls_insecure_skip_verify
          }''}
        ${handleErrors}
      }

      # Code Server IDE (WebSocket support is automatic in Caddy)
      ide.diegonmarcos.com {
    ${sec}
        ${mkProtected "${flex}:8443"}
        ${handleErrors}
      }

      # NocoDB
      db.diegonmarcos.com {
    ${sec}
        ${mkProtected "${flex}:8085"}
        ${handleErrors}
      }

      # Grist Sheets
      sheets.diegonmarcos.com {
    ${sec}
        ${mkProtected "${flex}:3011"}
        ${handleErrors}
      }

      # Caddy admin API
      proxy.diegonmarcos.com {
    ${sec}
        ${mkProtected "localhost:${toString config.admin_port}"}
        ${handleErrors}
      }

      # Vaultwarden — reachable via npm_default docker network
      # Authelia access_control handles: API/identity/icons bypass, admin two_factor
      vault.diegonmarcos.com {
    ${sec}
        ${mkProtected "vaultwarden:80"}
        ${handleErrors}
      }

      # ntfy notifications
      rss.diegonmarcos.com {
    ${sec}
        ${mkProtected "${gcp}:8090"}
        ${handleErrors}
      }

      # ════════════════════════════════════════════════════════════
      # CATCH-ALL — Custom error page for unknown/unconfigured domains
      # ════════════════════════════════════════════════════════════

      *.diegonmarcos.com {
    ${secNoLimit}
        tls {
          dns cloudflare {env.CF_API_TOKEN}
        }
        root * /srv
        rewrite * /error.html
        file_server
      }

    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        caddy:
          image: ghcr.io/diegonmarcos/caddy-custom:latest
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .secrets
          ports:
            - "${toString config.http_port}:80"
            - "${toString config.https_port}:443"
            - "${toString config.https_port}:443/udp"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - ./error.html:/srv/error.html:ro
            - ./logs:/var/log/caddy
            - caddy_data:/data
            - caddy_config:/config
          networks:
            - npm_default
          depends_on:
            introspect-proxy:
              condition: service_healthy

        introspect-proxy:
          build: ./introspect-proxy
          image: introspect-proxy:latest
          container_name: introspect-proxy
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            INTROSPECT_URL: https://auth.diegonmarcos.com/api/oidc/introspection
            CLIENT_ID: cli
            CLIENT_SECRET: ''${AUTHELIA_CLI_SECRET}
          networks:
            - npm_default
          deploy:
            resources:
              limits:
                memory: 96M
              reservations:
                memory: 48M
          healthcheck:
            test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:4182/health')"]
            interval: 30s
            timeout: 5s
            retries: 3
            start_period: 10s

      volumes:
        caddy_data:
          driver: local
        caddy_config:
          driver: local

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "caddy-configs" {} ''
        mkdir -p $out/introspect-proxy/app
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkCaddyfile pkgs} $out/Caddyfile
        cp ${./error.html} $out/error.html
        cp ${./introspect-proxy/Dockerfile} $out/introspect-proxy/Dockerfile
        cp ${./introspect-proxy/app/main.py} $out/introspect-proxy/app/main.py
        cp ${./introspect-proxy/app/requirements.txt} $out/introspect-proxy/app/requirements.txt
      '';
    });
  };
}
