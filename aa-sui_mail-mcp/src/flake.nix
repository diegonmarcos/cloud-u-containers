{
  description = "Mail MCP Server - IMAP/SMTP/Admin mail tools for Claude";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    # Single source of truth: build-mail-mcp.json (symlink → 2_configs/dist/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-mail-mcp.json);
    svc = buildContainer.services;
    mh = buildJson.mail_hosts;
    mp = buildJson.mail_ports;

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      # Use domain for TLS cert match (cert is for mail.<base>, not WG IP)
      mail_host = mh.maddy;
      port = ports.valueOf "app";
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
          restart: "no"  # container-init handles startup
          ports:
            - "${svc."mail-mcp".ip}:${toString config.port}:${toString config.port}"
          env_file:
            - .secrets
          environment:
            PORT: "${toString config.port}"
            MAIL_HOST: ${config.mail_host}
            MADDY_HOST: "${mh.maddy}"
            MADDY_IMAP_PORT: "${toString mp.maddy_imap}"
            MADDY_SMTP_PORT: "${toString mp.maddy_smtp}"
            STALWART_HOST: "${mh.stalwart}"
            STALWART_IMAP_PORT: "${toString mp.stalwart_imap}"
            STALWART_SMTP_PORT: "${toString mp.stalwart_smtp}"
            STALWART_JMAP_URL: "https://${mh.stalwart}:${toString mp.stalwart_jmap_https}"

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
