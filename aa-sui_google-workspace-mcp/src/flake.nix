{
  description = "Google Workspace MCP Server — Gmail, Calendar, Drive, Docs, Sheets via HTTP transport";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    # Single source of truth: build-google-workspace-mcp.json (symlink → I_cloud-data/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-google-workspace-mcp.json);
    svc = buildContainer.services;

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      port = ports.valueOf "app";
      user_google_email = buildJson.user_google_email;
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
          restart: "no"  # container-init handles startup
          network_mode: host
          environment:
            WORKSPACE_MCP_HOST: "${svc."google-workspace-mcp".ip}"
            WORKSPACE_MCP_PORT: "${toString config.port}"
            PORT: "${toString config.port}"
            USER_GOOGLE_EMAIL: "${config.user_google_email}"
            GOOGLE_SERVICE_ACCOUNT_KEY_PATH: "/run/secrets/service-account-key.json"
          volumes:
            - ./.secrets.d/GOOGLE_SERVICE_ACCOUNT_KEY:/run/secrets/service-account-key.json:ro
          healthcheck:
            test: ["CMD", "curl", "-f", "http://${svc."google-workspace-mcp".ip}:${toString config.port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

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
