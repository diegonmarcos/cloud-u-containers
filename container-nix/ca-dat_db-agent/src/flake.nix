{
  description = "db-agent - Central database backup service (all VMs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "db-agent";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # db-agent - Central database backup service
      # Deploy to: ALL VMs
      # Runs daily, auto-detects databases, dumps + logs

      services:
        db-agent:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          mem_limit: 64m
          cpus: 0.1
          environment:
            - VM_NAME=''${VM_NAME:-unknown}
            - SCHEDULE=''${SCHEDULE:-0 3 * * *}
            - NTFY_URL=''${NTFY_URL:-http://ntfy:80}
            - NTFY_TOPIC=''${NTFY_TOPIC:-backup}
            - RETENTION_DAYS=''${RETENTION_DAYS:-7}
            - BUP_REMOTE=''${BUP_REMOTE:-}
            - TZ=UTC
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - db-agent-data:/backup
            - db-agent-logs:/var/log/db-agent
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "test", "-f", "/var/log/db-agent/last-run.json"]
            interval: 60s
            timeout: 5s
            retries: 3
            start_period: 120s
          logging:
            driver: "json-file"
            options:
              max-size: "5m"
              max-file: "3"

      volumes:
        db-agent-data:
          name: db-agent-data
        db-agent-logs:
          name: db-agent-logs

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "db-agent-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
