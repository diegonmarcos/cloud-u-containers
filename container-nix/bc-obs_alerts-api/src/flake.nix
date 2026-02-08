{
  description = "Alerts API - Security alert aggregation service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "alerts-api";
      port = 5050;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        alerts-api:
          container_name: ${config.container_name}
          build: .
          restart: unless-stopped
          cpus: "0.1"
          mem_limit: 64m
          ports:
            - "${toString config.port}:5000"
          volumes:
            - alerts-data:/data
          environment:
            - DB_PATH=/data/alerts.db
            - NTFY_URL=https://rss.diegonmarcos.com
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:5000/api/health"]
            interval: 30s
            timeout: 10s
            retries: 3

      volumes:
        alerts-data:

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "alerts-api-configs" {} ''
        mkdir -p $out/app
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./requirements.txt} $out/requirements.txt
        cp ${./app/main.py} $out/app/main.py
      '';
    });
  };
}
