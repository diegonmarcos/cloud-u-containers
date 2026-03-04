{
  description = "Mailu MCP Server - IMAP/SMTP/Admin mail tools for Claude";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "mailu-mcp";
      image = "mailu-mcp:latest";
      mail_host = "imap.diegonmarcos.com";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        mailu-mcp:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            MAIL_HOST: ${config.mail_host}
          networks:
            - mail-net

      networks:
        mail-net:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.linkFarm "mailu-mcp-dist" [
        { name = "docker-compose.yml"; path = mkDockerCompose pkgs; }
      ];
    });
  };
}
