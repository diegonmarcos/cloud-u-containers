# compose.nix — docker-compose spec for etherpad (multi-container: app + db).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
#
# Two services share the VM network (network_mode: host):
#   etherpad  — upstream wrapped into <name>-binaries:latest (app)
#   postgres  — postgres:16-alpine (db); UID-mismatch fix via entrypoint
{ buildJson, container, containerDb }:

let
  app = buildJson.containers.app;   # etherpad
  db  = buildJson.containers.db;    # postgres

  # Engine emits dist/code/<arch>/Dockerfile wrapping buildJson.upstream_image
  # and ships it to GHCR as <name>-binaries:latest. The etherpad container
  # pulls this image at runtime.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  appPort = toString buildJson.ports.app;
  dbPort  = toString buildJson.ports.db;
  dbUser  = db.db_user;
  dbName  = db.db_name;
in
{
  services = {
    etherpad = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        TITLE             = "Etherpad";
        DEFAULT_PAD_TEXT  = "Welcome to Etherpad!";
        ADMIN_PASSWORD    = "\${ETHERPAD_ADMIN_PASSWORD:-changeme}";
        DB_TYPE           = "postgres";
        DB_HOST           = "localhost";
        DB_PORT           = dbPort;
        DB_NAME           = dbName;
        DB_USER           = dbUser;
        DB_PASS           = dbUser;
        TRUST_PROXY       = "true";
        LOGLEVEL          = "INFO";
        PORT              = appPort;
      };
      volumes = [ "etherpad_data:/opt/etherpad-lite/var" ];
      healthcheck = {
        test     = [ "CMD" "curl" "-f" "http://localhost:${appPort}/" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
      depends_on.postgres = { condition = "service_healthy"; };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };

    postgres = {
      image = db.image;
      container_name = db.container_name;
      network_mode = "host";
      # Fix UID mismatch (Debian postgres=999 vs Alpine postgres=70)
      entrypoint = [
        "sh" "-c"
        "chown -R postgres:postgres /var/lib/postgresql/data 2>/dev/null; exec docker-entrypoint.sh postgres"
      ];
      environment = {
        POSTGRES_USER     = dbUser;
        POSTGRES_PASSWORD = dbUser;
        POSTGRES_DB       = dbName;
        PGDATA            = "/var/lib/postgresql/data/pgdata";
        PGPORT            = dbPort;
      };
      volumes = [ "postgres_data:/var/lib/postgresql/data" ];
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U ${dbUser} -p ${dbPort}" ];
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
    etherpad_data = {};
    postgres_data = {};
  };
}
