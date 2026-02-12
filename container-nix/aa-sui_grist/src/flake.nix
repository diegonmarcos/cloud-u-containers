{
  description = "Grist - Modern collaborative spreadsheet (Google Sheets alternative)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "sheets.diegonmarcos.com";
      container_name = "grist_app";
      image = "gristlabs/grist:latest";
      port = 3011;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Grist - Modern collaborative spreadsheet
      # Deployed on: oci-p-flex_1 (Oracle Flex)

      services:
        grist:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: always
          ports:
            - "${toString config.port}:8484"
          volumes:
            - grist_data:/persist
          environment:
            - GRIST_SESSION_SECRET=changeme-secret-key
            - GRIST_SINGLE_ORG=docs
            - GRIST_DEFAULT_EMAIL=''${GRIST_ADMIN_EMAIL:-admin@diegonmarcos.com}
            - APP_HOME_URL=https://${config.domain}
            - GRIST_SANDBOX_FLAVOR=unsandboxed
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'curl', '-f', 'http://localhost:8484/']
            interval: 30s
            timeout: 10s
            retries: 3

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        grist_data:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "grist-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
