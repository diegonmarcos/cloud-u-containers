{
  description = "C3 Services — Unified service API gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "c3-services-mcp-api";
      image = "ghcr.io/diegonmarcos/c3-services-mcp-api:latest";
      port = 8082;
      mcp_http_port = 3101;
    };

    title = "C3 Services — Unified Service API Gateway";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_c3-services-mcp-api/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_c3-services-mcp-api/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        c3-services-mcp-api:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          networks:
            - c3-net
          ports:
            - "${toString config.port}:8080"
            - "10.0.0.6:${toString config.mcp_http_port}:${toString config.mcp_http_port}"
          env_file:
            - .secrets
          environment:
            - PORT=8080
            - NODE_ENV=production
            - MCP_HTTP_PORT=${toString config.mcp_http_port}
            - AUTHELIA_OIDC_CLIENT_ID=c3-services-mcp-api
            - AUTHELIA_OIDC_CLIENT_SECRET=''${AUTHELIA_OIDC_C3_SERVICES_SECRET}
            - AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

      networks:
        c3-net:
          external: true
          name: mattermost-bots_default
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.''${system};
    in let
      defaultPkg = pkgs.runCommand "c3-services-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
    });
  };
}
