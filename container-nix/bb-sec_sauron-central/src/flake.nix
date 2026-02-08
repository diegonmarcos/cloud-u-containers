{
  description = "Sauron Central - Syslog collector + SIEM API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Central Syslog Collector - Deploy on GCP arch-1
      # Receives alerts from all VMs, stores in SQLite

      services:
        syslog-central:
          image: balabit/syslog-ng:4.4.0
          container_name: syslog-central
          restart: unless-stopped
          ports:
            - "5514:5514/tcp"
          volumes:
            - ./syslog-ng-central.conf:/etc/syslog-ng/syslog-ng.conf:ro
            - siem-data:/var/log/siem
          networks:
            - security

        siem-api:
          image: python:3.11-slim
          container_name: siem-api
          restart: unless-stopped
          build:
            context: .
            dockerfile: Dockerfile.api
          ports:
            - "127.0.0.1:8080:8080"
          volumes:
            - siem-data:/var/log/siem:ro
            - ./api:/app:ro
          environment:
            - DB_PATH=/var/log/siem/alerts.db
          networks:
            - security

      volumes:
        siem-data:

      networks:
        security:
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "sauron-central-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        mkdir -p $out/api
        cp ${./syslog-ng-central.conf} $out/syslog-ng-central.conf
        cp ${./Dockerfile.api} $out/Dockerfile.api
        cp ${./api/app.py} $out/api/app.py
      '';
    });
  };
}
