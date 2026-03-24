{
  description = "C3 REST API — Cloud Control Center Fastify API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "c3-infra-api";
      image = "ghcr.io/diegonmarcos/c3-infra-api:latest";
      port = 8081;
    };

    title = "C3 REST API";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_c3-infra-api/src/flake.nix   ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_c3-infra-api/build.sh ship  ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        c3-infra-api:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          network_mode: host
          volumes:
            - /opt/ssh-keys/c3-infra-api:/root/.ssh:ro
            - /nix/store:/nix/store:ro
            - ~/.nix-profile/bin:/usr/local/nix-bin:ro
            - ~/.config/gcloud:/root/.config/gcloud
            - c3_git_repos:/root/git
          env_file:
            - .secrets
          environment:
            - PORT=${toString config.port}
            - NODE_ENV=production
            - GIT_BASE=/root/git
            - AUTHELIA_OIDC_CLIENT_ID=c3-infra-api
            - AUTHELIA_OIDC_CLIENT_SECRET=''${AUTHELIA_OIDC_C3_INFRA_MCP_SECRET}
            - AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token
            - RESEND_API_KEY=''${RESEND_API_KEY}
            - CF_API_KEY=''${CF_API_KEY}
            - CF_API_EMAIL=''${CF_API_EMAIL}
            - PATH=/usr/local/nix-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:${toString config.port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

      volumes:
        c3_git_repos:
          driver: local

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "c3-infra-api-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
    });
  };
}
