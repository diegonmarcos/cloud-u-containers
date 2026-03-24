{
  description = "C3 Services REST API — service API gateway Fastify API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "c3-services-api";
      image = "ghcr.io/diegonmarcos/c3-services-api:latest";
      port = 8082;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: bc-obs_c3-services-api/src/flake.nix                   ║
      # ║ Rebuild: bc-obs_c3-services-api/build.sh ship                  ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        c3-services-api:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          network_mode: host
          env_file:
            - .secrets
          environment:
            - PORT=${toString config.port}
            - NODE_ENV=production
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:${toString config.port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "c3-services-api-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
    });
  };
}
