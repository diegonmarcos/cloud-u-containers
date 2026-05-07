# compose.nix — docker-compose spec for photos-webhook (multi-container: app + db).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
#
# Two services on the default compose network:
#   photos-webhook  — Type A (own Python code), wraps dist/code/<arch>/Dockerfile
#                     via <name>-binaries image; listens on WG IP:<app port>.
#   photos-db       — postgres:16-alpine upstream; schema.sql mounted as an
#                     init script into /docker-entrypoint-initdb.d/ (no
#                     separate db image needed — the engine produces a single
#                     binaries image per service).
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  db  = buildJson.containers.db;

  appPort = toString buildJson.ports.app;

  # Engine emits dist/code/<arch>/Dockerfile and ships it as the
  # <name>-binaries:latest GHCR image. photos-webhook container pulls this.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    "${db.container_name}" = {
      image = db.image;
      container_name = db.container_name;
      platform = "linux/${buildJson.docker.arch}";
      environment = {
        POSTGRES_DB       = db.db_name;
        POSTGRES_USER     = db.db_user;
        POSTGRES_PASSWORD = "\${DB_PASSWORD:-SECURE_PASSWORD_HERE}";
      };
      volumes = [
        "photos_db_data:/var/lib/postgresql/data"
        "./assets/schema.sql:/docker-entrypoint-initdb.d/01-schema.sql:ro"
      ];
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U ${db.db_user} -d ${db.db_name}" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };

    photos-webhook = {
      image = binariesImage;
      container_name = app.container_name;
      platform = "linux/${buildJson.docker.arch}";
      env_file = [ ".secrets" ];
      environment = {
        DB_HOST       = db.container_name;
        DB_NAME       = db.db_name;
        DB_USER       = db.db_user;
        DB_PASSWORD   = "\${DB_PASSWORD:-SECURE_PASSWORD_HERE}";
        S3_ACCESS_KEY = "\${S3_ACCESS_KEY}";
        S3_SECRET_KEY = "\${S3_SECRET_KEY}";
        S3_REGION     = buildJson.s3.region;
        S3_BUCKET     = buildJson.s3.bucket;
        WEBHOOK_PORT  = appPort;
      };
      ports = [ "${svc."photos-webhook".ip}:${appPort}:${appPort}" ];
      depends_on.${db.container_name} = { condition = "service_healthy"; };
      healthcheck = {
        test     = [ "CMD" "curl" "-f" "http://localhost:${appPort}/health" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };

  volumes = {
    photos_db_data = { driver = "local"; };
  };
}
