{
  description = "HedgeDoc - Collaborative markdown editor (notes.diegonmarcos.com)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "notes.diegonmarcos.com";
      container_name = "hedgedoc_app";
      image = "quay.io/hedgedoc/hedgedoc:latest";
      db_container = "hedgedoc_postgres";
      db_image = "postgres:16-alpine";
      port = 3010;
      db_user = "hedgedoc";
      db_name = "hedgedoc";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # HedgeDoc - Collaborative markdown editor
      # Real-time collaboration on markdown documents
      # Deployed on: oci-A1-f_1 (Oracle Flex)

      services:
        hedgedoc:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"
          ports:
            - "${toString config.port}:3000"
          depends_on:
            hedgedoc_postgres:
              condition: service_healthy
          volumes:
            - hedgedoc_uploads:/hedgedoc/public/uploads
          environment:
            - CMD_DB_URL=postgres://${config.db_user}:${config.db_user}@${config.db_container}:5432/${config.db_name}
            - CMD_DOMAIN=${config.domain}
            - CMD_PROTOCOL_USESSL=true
            - CMD_URL_ADDPORT=false
            - CMD_ALLOW_ANONYMOUS=true
            - CMD_ALLOW_ANONYMOUS_EDITS=true
            - CMD_ALLOW_FREEURL=true
            - CMD_DEFAULT_PERMISSION=freely
            - CMD_SESSION_SECRET=hedgedoc-secret-change-me
            - CMD_EMAIL=true
            - CMD_ALLOW_EMAIL_REGISTER=true
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:3000/status']
            interval: 30s
            timeout: 10s
            retries: 5
            start_period: 30s

        hedgedoc_postgres:
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
        hedgedoc_uploads:
          driver: local
        postgres_data:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "hedgedoc-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
