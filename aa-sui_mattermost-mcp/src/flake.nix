{
  description = "Mattermost MCP Server — chat tools for Claude via HTTP transport";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    buildContainer = builtins.fromJSON (builtins.readFile ./build-mattermost-mcp.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    svc = buildContainer.services;

    config = {
      container_name = buildContainer.container.container_name;
      image = buildJson.upstream_image;
      port = ports.valueOf "app";
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
          restart: "no"  # container-init handles startup
          ports:
            - "${svc."mattermost-mcp".ip}:${toString config.port}:${toString config.port}"
          env_file:
            - .secrets
          environment:
            MCP_HTTP_PORT: "${toString config.port}"

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
