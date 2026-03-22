{
  description = "Mail MCP Server - IMAP/SMTP/Admin mail tools for Claude";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "mail-mcp";
      image = "ghcr.io/diegonmarcos/mail-mcp:latest";
      mail_host = "mail.diegonmarcos.com";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_mail-mcp/src/flake.nix  ║
      # ║ Rebuild: ~/git/cloud/a_solutions/aa-sui_mail-mcp/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        mail-mcp:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          network_mode: host
          env_file:
            - .secrets
          environment:
            MAIL_HOST: ${config.mail_host}

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.linkFarm "mail-mcp-dist" [
        { name = "docker-compose.yml"; path = mkDockerCompose pkgs; }
      ];
    });
  };
}
