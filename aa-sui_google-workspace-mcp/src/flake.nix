{
  description = "Google Workspace MCP Server — Gmail, Calendar, Drive, Docs, Sheets via HTTP transport";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "google-workspace-mcp";
      image = "google-workspace-mcp:latest";
      port = 3104;
      internal_port = 8000;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_google-workspace-mcp/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/aa-sui_google-workspace-mcp/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        google-workspace-mcp:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            WORKSPACE_MCP_HOST: "0.0.0.0"
            WORKSPACE_MCP_PORT: "${toString config.internal_port}"
            USER_GOOGLE_EMAIL: "me@diegonmarcos.com"
            GOOGLE_SERVICE_ACCOUNT_KEY_PATH: "/run/secrets/service-account-key.json"
          dns:
            - 172.21.0.2
          networks:
            infra:
              ipv4_address: 172.21.0.81
          ports:
            - "10.0.0.6:${toString config.port}:${toString config.internal_port}"
          volumes:
            - ./.secrets.d/GOOGLE_SERVICE_ACCOUNT_KEY:/run/secrets/service-account-key.json:ro
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:${toString config.internal_port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

      networks:
        infra:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.linkFarm "google-workspace-mcp-dist" [
        { name = "docker-compose.yml"; path = mkDockerCompose pkgs; }
      ];
    });
  };
}
