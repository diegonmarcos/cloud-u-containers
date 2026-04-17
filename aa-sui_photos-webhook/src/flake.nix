{
  description = "Photos Webhook - PostgreSQL + webhook processor for PhotoPrism";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    config = {
      db_container = "photos-db";
      db_image = "postgres:16-alpine";
      webhook_container = "photos-webhook";
      db_name = "photos";
      db_user = "photos_user";
    };

    title = "Photos Webhook - PostgreSQL + webhook processor for PhotoPrism";

    docker = import ../../_shared/docker.nix;

    ghcr-photos-db = docker.mkGhcrBuild {
      name = "photos-webhook-db";
      fromImage = config.db_image;
      configFiles = [
        { src = "schema.sql"; dst = "/docker-entrypoint-initdb.d/01-schema.sql"; }
      ];
    };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_photos-webhook/src/flake.nix";
      volumes = {
        photos_db_data = { driver = "local"; };
      };
      services = {
        photos-db = docker.mkService {
          name = "photos-db";
          image = ghcr-photos-db.image;
          build = ghcr-photos-db.build;
          container_name = config.db_container;
          restart = "no";
          skipReadOnly = true;
          environment = {
            POSTGRES_DB = config.db_name;
            POSTGRES_USER = config.db_user;
            POSTGRES_PASSWORD = "\${DB_PASSWORD:-SECURE_PASSWORD_HERE}";
          };
          volumes = [
            "photos_db_data:/var/lib/postgresql/data"
          ];
          healthcheck = {
            test = ''["CMD-SHELL", "pg_isready -U ${config.db_user} -d ${config.db_name}"]'';
            interval = "10s";
            timeout = "5s";
            retries = 5;
          };
        };
        photos-webhook = docker.mkService {
          name = "photos-webhook";
          image = "ghcr.io/diegonmarcos/photos-webhook:latest";
          build = { context = "."; dockerfile = "Dockerfile"; };
          container_name = config.webhook_container;
          restart = "no";
          skipReadOnly = true;
          environment = {
            DB_HOST = "localhost";
            DB_NAME = config.db_name;
            DB_USER = config.db_user;
            DB_PASSWORD = "\${DB_PASSWORD:-SECURE_PASSWORD_HERE}";
            S3_ACCESS_KEY = "\${S3_ACCESS_KEY}";
            S3_SECRET_KEY = "\${S3_SECRET_KEY}";
            S3_REGION = "eu-marseille-1";
            S3_BUCKET = "photos";
            WEBHOOK_PORT = "\"${toString (ports.valueOf "app")}\"";
          };
          depends_on = { photos-db = { condition = "service_healthy"; }; };
          volumes = [
            "./webhook.py:/app/webhook.py:ro"
            "./requirements.txt:/app/requirements.txt:ro"
          ];
          command = "python webhook.py flask";
          healthcheck = {
            test = ''["CMD", "curl", "-f", "http://localhost:${toString (ports.valueOf "app")}/health"]'';
            interval = "10s";
            timeout = "5s";
            retries = 5;
          };
        };
      };
    };


  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "photos-webhook-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./requirements.txt} $out/requirements.txt
        cp ${./webhook.py} $out/webhook.py
        cp ${./schema.sql} $out/schema.sql
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
