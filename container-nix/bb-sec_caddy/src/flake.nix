{
  description = "Caddy - Declarative reverse proxy with automatic HTTPS (replaces NPM on gcp-proxy + oci-mail)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "caddy";
      image = "caddy:2-alpine";
      http_port = 80;
      https_port = 443;
      admin_port = 2019;
    };

    # WireGuard IPs
    gcp = "10.0.0.1";       # gcp-proxy
    flex = "10.0.0.2";      # oci-flex (on-demand)
    mail = "10.0.0.3";      # oci-mail
    analytics = "10.0.0.4"; # oci-analytics

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
    mkProtectedCustom = upstreamBlock: ''
      @bearer header Authorization Bearer*
      handle @bearer {
    ${bearer}
        ${upstreamBlock}
      }
      handle {
    ${authelia}
        ${upstreamBlock}
      }
    '';

    mkCaddyfile = pkgs: pkgs.writeText "Caddyfile" ''
      {
        admin localhost:${toString config.admin_port}
      }

      # ── Snippet: custom error page for backend failures ──
      (error_page) {
        handle_errors {
          respond "CADDY_CUSTOM_ERROR_{err.status_code}" {err.status_code}
        }
      }

      # ════════════════════════════════════════════════════════════
      # PUBLIC / BYPASS (no auth)
      # ════════════════════════════════════════════════════════════

      # Authelia itself — must be public (bypass policy in Authelia config)
      auth.diegonmarcos.com {
        import error_page
        reverse_proxy authelia:9091
      }

      # API — Flask + Rust backends
      api.diegonmarcos.com {
        import error_page
        handle /rust/* {
          reverse_proxy ${gcp}:8080
        }
        handle {
          reverse_proxy ${gcp}:5000
        }
      }

      # Radicale CalDAV/CardDAV
      cal.diegonmarcos.com {
        import error_page
        reverse_proxy ${flex}:5232
      }

      # Affine collaborative docs (100MB uploads, long timeouts)
      drive-notes-affine.diegonmarcos.com {
        import error_page
        request_body {
          max_size 100MB
        }
        reverse_proxy ${flex}:3010 {
          transport http {
            read_timeout 3600s
            write_timeout 3600s
          }
        }
      }

      # ── GitHub Pages reverse proxies (URL stays as subdomain) ──

      # Landing page
      diegonmarcos.com, www.diegonmarcos.com {
        import error_page
        ${mkGithubProxy "landpage"}
      }

      # Linktree
      linktree.diegonmarcos.com {
        import error_page
        ${mkGithubProxy "linktree"}
      }

      # Cloud dashboard
      cloud.diegonmarcos.com {
        import error_page
        ${mkGithubProxy "cloud"}
      }

      # Nexus
      nexus.diegonmarcos.com {
        import error_page
        ${mkGithubProxy "nexus"}
      }

      # Suite apps dashboard
      suite.diegonmarcos.com {
        import error_page
        ${mkGithubProxy "suite"}
      }

      # ════════════════════════════════════════════════════════════
      # ANALYTICS — Matomo (public tracking + protected admin)
      # ════════════════════════════════════════════════════════════

      analytics.diegonmarcos.com {
        import error_page
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
      }

      # ════════════════════════════════════════════════════════════
      # AUTHELIA-PROTECTED (bearer token bypass for CLI/API)
      # ════════════════════════════════════════════════════════════

      # PhotoPrism
      photos.diegonmarcos.com {
        import error_page
        # Root path → landing page (replaces Cloudflare redirect rule)
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/myphotos/ permanent
        }

        # All other paths → auth + PhotoPrism
        ${mkProtected "${flex}:3013"}
      }

      # Syncthing
      sync.diegonmarcos.com {
        import error_page
        ${mkProtected "${mail}:8384"}
      }

      # Mailu webmail (upstream is HTTPS with self-signed cert)
      mail.diegonmarcos.com {
        import error_page
        # Root path → landing page (replaces Cloudflare redirect rule)
        @root path /
        handle @root {
          redir https://diegonmarcos.github.io/mymail/ permanent
        }

        # All other paths → auth + Mailu
        ${mkProtectedCustom ''reverse_proxy https://${mail}:8444 {
          transport http {
            tls_insecure_skip_verify
          }
        }''}
      }

      # Code Server IDE (WebSocket support is automatic in Caddy)
      ide.diegonmarcos.com {
        import error_page
        ${mkProtected "${flex}:8443"}
      }

      # NocoDB
      db.diegonmarcos.com {
        import error_page
        ${mkProtected "${flex}:8085"}
      }

      # Grist Sheets
      sheets.diegonmarcos.com {
        import error_page
        ${mkProtected "${flex}:3011"}
      }

      # Caddy admin API
      proxy.diegonmarcos.com {
        import error_page
        ${mkProtected "localhost:${toString config.admin_port}"}
      }

      # Vaultwarden — reachable via npm_default docker network
      # Authelia access_control handles: API/identity/icons bypass, admin two_factor
      vault.diegonmarcos.com {
        import error_page
        ${mkProtected "vaultwarden:80"}
      }

      # ntfy notifications
      rss.diegonmarcos.com {
        import error_page
        ${mkProtected "${gcp}:8090"}
      }

      # ════════════════════════════════════════════════════════════
      # CATCH-ALL — Custom error page for unknown/unconfigured domains
      # ════════════════════════════════════════════════════════════

      :443 {
        tls internal
        root * /srv
        rewrite * /error.html
        file_server
      }

    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        caddy:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.http_port}:80"
            - "${toString config.https_port}:443"
            - "${toString config.https_port}:443/udp"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - ./error.html:/srv/error.html:ro
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
            - .env
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
