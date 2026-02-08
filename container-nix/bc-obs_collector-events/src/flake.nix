{
  description = "Event Collector - Docker container metrics forwarder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Event Collector - Docker container metrics forwarder
      # Deployed on: gcp-f-micro_1 (35.226.147.64)

      services:
        collector:
          container_name: collector
          build: .
          restart: unless-stopped
          mem_limit: 16m
          mem_reservation: 8m
          cpus: 0.05
          environment:
            - VM_NAME=''${VM_NAME:-unknown}
            - NTFY_URL=http://ntfy:80
            - INTERVAL=300
            - TIMEOUT=10
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "pgrep", "-f", "entrypoint"]
            interval: 60s
            timeout: 5s
            retries: 3
          logging:
            driver: "json-file"
            options:
              max-size: "2m"
              max-file: "2"

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "collector-events-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
