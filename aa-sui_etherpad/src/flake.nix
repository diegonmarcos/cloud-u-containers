{
  description = "Etherpad - Real-time collaborative document editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-etherpad_{app,postgres}.json (symlinks → 2_configs/dist/).
    # Engine resolves symlinks before nix build.
    buildApp = builtins.fromJSON (builtins.readFile ./build-etherpad_app.json);
    buildDb = builtins.fromJSON (builtins.readFile ./build-etherpad_postgres.json);

    config = {
      domain = buildJson.domain;
      container_name = buildApp.container.container_name;
      db_container = buildDb.container.container_name;
      port = buildJson.ports.app;
      db_port = toString buildJson.ports.db;
      db_user = buildDb.container.db_user;
      db_name = buildDb.container.db_name;
    };

    title = "Etherpad - Real-time collaborative document editor";

    ghcr-etherpad = docker.mkGhcrBuild {
      name = "etherpad";
      fromImage = buildJson.upstream_image;
    };

    ghcr-etherpad-db = docker.mkGhcrBuild {
      name = "etherpad-db";
      fromImage = buildDb.container.image;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_etherpad/src/flake.nix";
        services = {
          etherpad = docker.mkService {
            name = "etherpad";
            image = ghcr-etherpad.image;
            build = ghcr-etherpad.build;
            container_name = config.container_name;
            portEnv = ports.envFor "app";
            skipReadOnly = true;
            volumes = [
              "etherpad_data:/opt/etherpad-lite/var"
            ];
            environment = [
              "TITLE=Etherpad"
              "DEFAULT_PAD_TEXT=Welcome to Etherpad!"
              "ADMIN_PASSWORD=\${ETHERPAD_ADMIN_PASSWORD:-changeme}"
              "DB_TYPE=postgres"
              "DB_HOST=localhost"
              "DB_PORT=${config.db_port}"
              "DB_NAME=${config.db_name}"
              "DB_USER=${config.db_user}"
              "DB_PASS=${config.db_user}"
              "TRUST_PROXY=true"
              "LOGLEVEL=INFO"
            ];
            healthcheck = {
              test = "['CMD', 'curl', '-f', 'http://localhost:${toString config.port}/']";
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
            image = ghcr-etherpad-db.image;
            build = ghcr-etherpad-db.build;
            container_name = config.db_container;
            portEnv = ports.envFor "db";
            skipReadOnly = true;
            # Fix UID mismatch: Debian postgres=999, Alpine postgres=70
            entrypoint = ["sh" "-c" "chown -R postgres:postgres /var/lib/postgresql/data 2>/dev/null; exec docker-entrypoint.sh postgres"];
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
              test = "['CMD-SHELL', 'pg_isready -U ${config.db_user} -p ${config.db_port}']";
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
