{
  description = "Etherpad - Real-time collaborative document editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

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

    title = "Etherpad - Real-time collaborative document editor";

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_etherpad/src/flake.nix";
        services = {
          etherpad = docker.mkService {
            name = "etherpad";
            image = config.image;
            container_name = config.container_name;
            ports = [ "10.0.0.6:${toString config.port}:9001" ];
            networks = [ "etherpad_net" ];
            volumes = [
              "etherpad_data:/opt/etherpad-lite/var"
            ];
            environment = [
              "TITLE=Etherpad"
              "DEFAULT_PAD_TEXT=Welcome to Etherpad!"
              "ADMIN_PASSWORD=\${ETHERPAD_ADMIN_PASSWORD:-changeme}"
              "DB_TYPE=postgres"
              "DB_HOST=${config.db_container}"
              "DB_PORT=5432"
              "DB_NAME=${config.db_name}"
              "DB_USER=${config.db_user}"
              "DB_PASS=${config.db_user}"
              "TRUST_PROXY=true"
              "LOGLEVEL=INFO"
            ];
            healthcheck = {
              test = "['CMD', 'curl', '-f', 'http://localhost:9001/']";
              interval = "30s";
              timeout = "10s";
              retries = 3;
            };
            depends_on = {
              postgres = {
                condition = "service_healthy";
              };
            };
          };

          postgres = docker.mkService {
            name = "postgres";
            image = config.db_image;
            container_name = config.db_container;
            networks = [ "etherpad_net" ];
            volumes = [
              "postgres_data:/var/lib/postgresql/data"
            ];
            environment = [
              "POSTGRES_USER=${config.db_user}"
              "POSTGRES_PASSWORD=${config.db_user}"
              "POSTGRES_DB=${config.db_name}"
              "PGDATA=/var/lib/postgresql/data/pgdata"
            ];
            healthcheck = {
              test = "['CMD-SHELL', 'pg_isready -U ${config.db_user}']";
              interval = "10s";
              timeout = "5s";
              retries = 5;
            };
          };
        };
        networks = {
          etherpad_net = {};
        };
        volumes = {
          etherpad_data = {};
          postgres_data = {};
        };
      };

      defaultPkg = pkgs.runCommand "etherpad-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
