{
  description = "HedgeDoc - Real-time collaborative markdown editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-hedgedoc_{app,postgres}.json (symlinks → 2_configs/dist/).
    # Engine resolves symlinks before nix build.
    buildApp = builtins.fromJSON (builtins.readFile ./build-hedgedoc_app.json);
    buildDb = builtins.fromJSON (builtins.readFile ./build-hedgedoc_postgres.json);

    config = {
      domain = buildJson.domain;
      container_name = buildApp.container.container_name;
      db_container = buildDb.container.container_name;
      port = buildJson.ports.app;
      db_port = buildJson.ports.db;
      db_user = buildDb.container.db_user;
      db_name = buildDb.container.db_name;
    };

    title = "HedgeDoc - Real-time collaborative markdown editor";

    ghcr-hedgedoc = docker.mkGhcrBuild {
      name = "hedgedoc";
      fromImage = buildJson.upstream_image;
    };

    ghcr-hedgedoc-db = docker.mkGhcrBuild {
      name = "hedgedoc-db";
      fromImage = buildDb.container.image;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_hedgedoc/src/flake.nix";
        services = {
          hedgedoc = docker.mkService {
            name = "hedgedoc";
            image = ghcr-hedgedoc.image;
            build = ghcr-hedgedoc.build;
            container_name = config.container_name;
            portEnv = ports.envFor "app";
            restart = "no";
            skipReadOnly = true;
            volumes = [
              "hedgedoc_uploads:/hedgedoc/public/uploads"
            ];
            environment = [
              "CMD_DOMAIN=${config.domain}"
              "CMD_URL_ADDPORT=false"
              "CMD_PROTOCOL_USESSL=true"
              "CMD_DB_URL=postgres://${config.db_user}:${config.db_user}@localhost:${toString config.db_port}/${config.db_name}"
              "CMD_ALLOW_EMAIL_REGISTER=true"
              "CMD_EMAIL=true"
              "CMD_ALLOW_FREEURL=true"
              "CMD_ALLOW_ANONYMOUS=true"
              "CMD_ALLOW_ANONYMOUS_EDITS=true"
              "CMD_DEFAULT_PERMISSION=freely"
              "CMD_SESSION_SECRET=\${CMD_SESSION_SECRET:-hedgedoc-secret-change-me}"
              "CMD_TRUST_PROXY=true"
              "CMD_LOGLEVEL=info"
            ];
            depends_on = {
              postgres = { condition = "service_healthy"; };
            };
          };

          postgres = docker.mkService {
            name = "postgres";
            image = ghcr-hedgedoc-db.image;
            build = ghcr-hedgedoc-db.build;
            container_name = config.db_container;
            portEnv = ports.envFor "db";
            restart = "no";
            skipReadOnly = true;
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
              test = "['CMD-SHELL', 'pg_isready -U ${config.db_user} -p ${toString config.db_port}']";
              interval = "10s";
              timeout = "5s";
              retries = 5;
            };
          };
        };
        volumes = {
          hedgedoc_uploads = {};
          postgres_data = {};
        };
      };

      defaultPkg = pkgs.runCommand "hedgedoc-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
