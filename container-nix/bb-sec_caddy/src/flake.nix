{
  description = "Caddy - Declarative reverse proxy with automatic HTTPS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "caddy";
      image = "caddy:2-alpine";
      http_port = 8880;
      https_port = 8443;
      admin_port = 2019;
    };

    p = toString config.http_port;

    # WireGuard IPs
    gcp = "10.0.0.1";    # gcp-proxy
    flex = "10.0.0.2";   # oci-flex (on-demand)
    mail = "10.0.0.3";   # oci-mail
    analytics = "10.0.0.4"; # oci-analytics

    # Authelia forward_auth via public endpoint (cookie-based, reachable from any VM)
    authelia = ''
        forward_auth https://auth.diegonmarcos.com {
          uri /api/authz/forward-auth
          copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        }'';

    # Bearer token auth via introspect-proxy sidecar (OIDC token introspection)
    bearer = ''
        forward_auth introspect-proxy:4182 {
          uri /auth
          copy_headers X-Auth-User X-Auth-Subject X-Auth-Email
        }'';

    mkCaddyfile = pkgs: pkgs.writeText "Caddyfile" ''
      {
        http_port ${p}
        https_port ${toString config.https_port}
        admin localhost:${toString config.admin_port}
        auto_https disable_redirects
      }

      :${p} {
        respond "Caddy is running" 200
      }

      # ── Authelia-protected (with bearer token bypass) ──────────────────
      http://photos.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy ${flex}:2342
        }
        handle {
      ${authelia}
          reverse_proxy ${flex}:2342
        }
      }

      http://sync.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy ${mail}:8384
        }
        handle {
      ${authelia}
          reverse_proxy ${mail}:8384
        }
      }

      http://proxy.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy localhost:${toString config.admin_port}
        }
        handle {
      ${authelia}
          reverse_proxy localhost:${toString config.admin_port}
        }
      }

      http://photos.app.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy ${flex}:3013
        }
        handle {
      ${authelia}
          reverse_proxy ${flex}:3013
        }
      }

      http://mail.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy https://${mail}:443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        }
        handle {
      ${authelia}
          reverse_proxy https://${mail}:443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        }
      }

      http://ide.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy ${flex}:8443
        }
        handle {
      ${authelia}
          reverse_proxy ${flex}:8443
        }
      }

      http://db.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy ${flex}:8085
        }
        handle {
      ${authelia}
          reverse_proxy ${flex}:8085
        }
      }

      http://analytics.diegonmarcos.com:${p} {
        @bearer header Authorization Bearer*
        handle @bearer {
      ${bearer}
          reverse_proxy ${mail}:8081
        }
        handle {
      ${authelia}
          reverse_proxy ${mail}:8081
        }
      }

      # vault — vaultwarden port not exposed on gcp-proxy host
      # rss — ntfy bound to localhost:8090 on gcp-proxy
      # logs — dozzle not running
      # docker — portainer not running

      # ── n8n (webhook bypass, no auth on webhooks) ──────────────────────
      http://n8n.diegonmarcos.com:${p} {
        @webhooks path /webhook/* /webhook-test/*
        handle @webhooks {
          reverse_proxy 84.235.234.87:5678
        }
        handle {
          reverse_proxy 84.235.234.87:5678
        }
      }

      http://app.gallery.diegonmarcos.com:${p} {
        reverse_proxy ${flex}:2342
      }

      # ── Public ─────────────────────────────────────────────────────────
      http://api.diegonmarcos.com:${p} {
        handle /rust/* {
          reverse_proxy ${gcp}:8080
        }
        handle {
          reverse_proxy ${gcp}:5000
        }
      }

      http://cal.diegonmarcos.com:${p} {
        reverse_proxy ${flex}:5232
      }

      http://drive-notes-affine.diegonmarcos.com:${p} {
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

      # disabled: vault, rss, logs, docker (see comments above)
    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        caddy:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.http_port}:${toString config.http_port}"
            - "${toString config.https_port}:${toString config.https_port}"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - caddy_data:/data
            - caddy_config:/config
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
