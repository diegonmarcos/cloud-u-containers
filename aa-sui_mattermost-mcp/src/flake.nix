{
  description = "Mattermost MCP Server — chat tools for Claude via HTTP transport";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "mattermost-mcp";
      image = "ghcr.io/diegonmarcos/mattermost-mcp:latest";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_mattermost-mcp/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/aa-sui_mattermost-mcp/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        mattermost-mcp:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          network_mode: host
          env_file:
            - .secrets
          environment:
            MM_URL: https://chat.diegonmarcos.com
            MM_TEAM_ID: x89hszqz97g6dxytbtx3p5mmkc
            MM_ADMIN_USERNAME: me@diegonmarcos.com
            CLAUDE_MODEL: opus

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.linkFarm "mattermost-mcp-dist" [
        { name = "docker-compose.yml"; path = mkDockerCompose pkgs; }
      ];
    });
  };
}
