{
  description = "Matomo Analytics (Hybrid Container) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "analytics.diegonmarcos.com";
      container_name = "matomo-hybrid";
      port = 8080;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Matomo Hybrid Container
      # VM: oci-f-micro_2 (129.151.228.66)
      # Domain: ${config.domain}
      #
      # Single container with:
      #   - Always-on: receiver-nginx + receiver-php-fpm (~30-50MB RAM)
      #   - On-demand: mariadb + matomo-php-fpm + matomo-nginx (~500-700MB RAM)
      #
      # Usage:
      #   docker compose up -d                                    # Start (receiver only)
      #   docker exec matomo-hybrid /scripts/matomo-wake.sh       # Wake full Matomo
      #   docker exec matomo-hybrid /scripts/matomo-sleep.sh      # Sleep Matomo

      services:
        matomo-hybrid:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:8080"
          volumes:
            - matomo_matomo_data:/var/www/html
            - matomo_matomo_db:/var/lib/mysql
            - matomo_inbox:/inbox
          environment:
            - MATOMO_DATABASE_HOST=localhost
            - MATOMO_DATABASE_USERNAME=''${MATOMO_DB_USER:-matomo}
            - MATOMO_DATABASE_PASSWORD=''${MATOMO_DB_PASSWORD:-<REDACTED-LEAK-2026-04-21>}
            - MATOMO_DATABASE_DBNAME=''${MATOMO_DB_NAME:-matomo}
            - MATOMO_API_TOKEN=''${MATOMO_API_TOKEN}
          deploy:
            resources:
              limits:
                memory: 1024M
              reservations:
                memory: 64M

      volumes:
        matomo_matomo_data:
          external: true
        matomo_matomo_db:
          external: true
        matomo_inbox:
          name: matomo_inbox
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "matomo-configs" {} ''
        mkdir -p $out/config $out/manage $out/receiver $out/scripts
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./matomo-hybrid/Dockerfile} $out/Dockerfile
        # Config files
        cp ${./matomo-hybrid/config/mariadb.cnf} $out/config/mariadb.cnf
        cp ${./matomo-hybrid/config/matomo-fpm.conf} $out/config/matomo-fpm.conf
        cp ${./matomo-hybrid/config/matomo-nginx.conf} $out/config/matomo-nginx.conf
        cp ${./matomo-hybrid/config/receiver-fpm.conf} $out/config/receiver-fpm.conf
        cp ${./matomo-hybrid/config/receiver-nginx.conf} $out/config/receiver-nginx.conf
        cp ${./matomo-hybrid/config/supervisord.conf} $out/config/supervisord.conf
        # Scripts
        cp ${./matomo-hybrid/scripts/entrypoint.sh} $out/scripts/entrypoint.sh
        cp ${./matomo-hybrid/scripts/import-inbox.sh} $out/scripts/import-inbox.sh
        cp ${./matomo-hybrid/scripts/matomo-sleep.sh} $out/scripts/matomo-sleep.sh
        cp ${./matomo-hybrid/scripts/matomo-wake.sh} $out/scripts/matomo-wake.sh
        # Management & receiver
        cp ${./matomo-hybrid/manage/matomo-manage.sh} $out/manage/matomo-manage.sh
        cp ${./matomo-hybrid/receiver/receive.php} $out/receiver/receive.php
      '';
    });
  };
}
