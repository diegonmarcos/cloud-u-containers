{
  description = "Etherpad - Real-time collaborative document editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "pad.diegonmarcos.com";
      container_name = "etherpad_app";
      image = "etherpad/etherpad:latest";
      db_container = "etherpad_postgres";
      db_image = "postgres:16-alpine";
      port = 3012;
      db_user = "etherpad";
      db_name = "etherpad";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Etherpad - Real-time collaborative document editor
      # Deployed on: oci-A1-f_1 (Oracle Flex)

      services:
        etherpad:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"
          ports:
            - "10.0.0.2:${toString config.port}:9001"
          volumes:
            - etherpad_data:/opt/etherpad-lite/var
          environment:
            - TITLE=Etherpad
            - DEFAULT_PAD_TEXT=Welcome to Etherpad!
            - ADMIN_PASSWORD=''${ETHERPAD_ADMIN_PASSWORD:-changeme}
            - DB_TYPE=postgres
            - DB_HOST=${config.db_container}
            - DB_PORT=5432
            - DB_NAME=${config.db_name}
            - DB_USER=${config.db_user}
            - DB_PASS=${config.db_user}
            - TRUST_PROXY=true
          depends_on:
            postgres:
              condition: service_healthy
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'curl', '-f', 'http://localhost:9001/']
            interval: 30s
            timeout: 10s
            retries: 3

        postgres:
          image: ${config.db_image}
          container_name: ${config.db_container}
          restart: "no"
          volumes:
            - postgres_data:/var/lib/postgresql/data
          environment:
            - POSTGRES_USER=${config.db_user}
            - POSTGRES_PASSWORD=${config.db_user}
            - POSTGRES_DB=${config.db_name}
            - PGDATA=/var/lib/postgresql/data/pgdata
          networks:
            - dev_network
          healthcheck:
            test: ['CMD-SHELL', 'pg_isready -U ${config.db_user}']
            interval: 10s
            timeout: 5s
            retries: 5

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        etherpad_data:
          driver: local
        postgres_data:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "etherpad-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
