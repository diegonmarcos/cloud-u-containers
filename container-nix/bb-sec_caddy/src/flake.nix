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
        auto_https off
      }

      # ── Health check ─────────────────────────────────────────────
      :80 {
        respond "Caddy is running" 200
      }

      # ════════════════════════════════════════════════════════════
      # PUBLIC / BYPASS (no auth)
      # ════════════════════════════════════════════════════════════

      # Authelia itself — must be public (bypass policy in Authelia config)
      http://auth.diegonmarcos.com {
        reverse_proxy authelia:9091
      }

      # API — Flask + Rust backends
      http://api.diegonmarcos.com {
        handle /rust/* {
          reverse_proxy ${gcp}:8080
        }
        handle {
          reverse_proxy ${gcp}:5000
        }
      }

      # Radicale CalDAV/CardDAV
      http://cal.diegonmarcos.com {
        reverse_proxy ${flex}:5232
      }

      # Affine collaborative docs (100MB uploads, long timeouts)
      http://drive-notes-affine.diegonmarcos.com {
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

      # ════════════════════════════════════════════════════════════
      # ANALYTICS — Matomo (public tracking + protected admin)
      # ════════════════════════════════════════════════════════════

      http://analytics.diegonmarcos.com {
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
      http://photos.diegonmarcos.com {
        ${mkProtected "${flex}:2342"}
      }

      # Syncthing
      http://sync.diegonmarcos.com {
        ${mkProtected "${mail}:8384"}
      }

      # Mailu webmail (upstream is HTTPS with self-signed cert)
      http://mail.diegonmarcos.com {
        ${mkProtectedCustom ''reverse_proxy https://${mail}:8444 {
          transport http {
            tls_insecure_skip_verify
          }
        }''}
      }

      # Code Server IDE (WebSocket support is automatic in Caddy)
      http://ide.diegonmarcos.com {
        ${mkProtected "${flex}:8443"}
      }

      # NocoDB
      http://db.diegonmarcos.com {
        ${mkProtected "${flex}:8085"}
      }

      # Caddy admin API
      http://proxy.diegonmarcos.com {
        ${mkProtected "localhost:${toString config.admin_port}"}
      }

      # Vaultwarden — reachable via npm_default docker network
      # Authelia access_control handles: API/identity/icons bypass, admin two_factor
      http://vault.diegonmarcos.com {
        ${mkProtected "vaultwarden:80"}
      }

      # ntfy notifications
      http://rss.diegonmarcos.com {
        ${mkProtected "${gcp}:8090"}
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
            - "8880:80"
            - "8443:443"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
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
        cp ${./introspect-proxy/Dockerfile} $out/introspect-proxy/Dockerfile
        cp ${./introspect-proxy/app/main.py} $out/introspect-proxy/app/main.py
        cp ${./introspect-proxy/app/requirements.txt} $out/introspect-proxy/app/requirements.txt
      '';
    });
  };
}
