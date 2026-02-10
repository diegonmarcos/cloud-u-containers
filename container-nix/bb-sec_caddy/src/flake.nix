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

    mkCaddyfile = pkgs: pkgs.writeText "Caddyfile" ''
      {
        http_port ${toString config.http_port}
        https_port ${toString config.https_port}
        admin 0.0.0.0:${toString config.admin_port}
      }

      :${toString config.http_port} {
        respond "Caddy is running" 200
      }

      analytics.diegonmarcos.com:${toString config.https_port} {
        reverse_proxy matomo-app:80
        tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/privkey.pem
      }

      sync.diegonmarcos.com:${toString config.https_port} {
        reverse_proxy syncthing:8384
        tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/privkey.pem
      }
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
            - "${toString config.admin_port}:${toString config.admin_port}"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - caddy_data:/data
            - caddy_config:/config
          networks:
            - matomo_default

      networks:
        matomo_default:
          external: true

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
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkCaddyfile pkgs} $out/Caddyfile
      '';
    });
  };
}
