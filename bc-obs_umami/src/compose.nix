# compose.nix — docker-compose spec for umami (multi-container: app + db + setup).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
#
# Three services (all on the default compose network so service names resolve):
#   umami        — upstream wrapped into <name>-binaries:latest (app, port bound to WG IP)
#   umami-db     — postgres:16-alpine (db, exposed internally only)
#   umami-setup  — curlimages/curl:latest (one-shot configuration job)
{ buildJson, container, containerDb, containerSetup, svc }:

let
  app   = buildJson.containers.app;
  db    = buildJson.containers.db;
  setup = buildJson.containers.setup;

  appPort = toString buildJson.ports.app;
  dbPort  = toString buildJson.ports.db;

  # Engine emits dist/code/<arch>/Dockerfile wrapping buildJson.upstream_image
  # and ships it to GHCR as <name>-binaries:latest. The umami container
  # pulls this image at runtime.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    umami = {
      image = binariesImage;
      container_name = app.container_name;
      ports = [ "${svc.umami.ip}:${appPort}:${appPort}" ];
      env_file = [ ".secrets" ];
      environment = {
        DATABASE_URL      = "postgresql://${db.db_user}:\${DB_PASSWORD}@${db.container_name}:${dbPort}/${db.db_name}";
        DATABASE_TYPE     = "postgresql";
        APP_SECRET        = "\${APP_SECRET}";
        PORT              = appPort;
        BASE_PATH         = "/umami";
        DISABLE_TELEMETRY = "1";
      };
      depends_on.${db.container_name} = { condition = "service_healthy"; };
      healthcheck = {
        test     = [ "CMD-SHELL" "curl -sf http://localhost:${appPort}/api/heartbeat || exit 1" ];
        interval = "15s";
        timeout  = "5s";
        retries  = 5;
        start_period = "30s";
      };
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };

    "${db.container_name}" = {
      image          = db.image;
      container_name = db.container_name;
      expose         = [ dbPort ];
      environment = {
        POSTGRES_DB       = db.db_name;
        POSTGRES_USER     = db.db_user;
        POSTGRES_PASSWORD = "\${DB_PASSWORD}";
        PGPORT            = dbPort;
      };
      command = [ "-p" dbPort ];
      volumes = [ "umami_db_data:/var/lib/postgresql/data" ];
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U ${db.db_user} -p ${dbPort}" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
      deploy.resources = {
        limits       = { memory = db.resources.limits.memory; };
        reservations = { memory = db.resources.reservations.memory; };
      };
    };

    "${setup.container_name}" = {
      image          = setup.image;
      container_name = setup.container_name;
      env_file       = [ ".secrets" ];
      depends_on.umami = { condition = "service_healthy"; };
      entrypoint     = [ "/bin/sh" "/setup/setup.sh" ];
      volumes = [
        "./configs/setup.sh:/setup/setup.sh:ro"
        "umami_config:/output"
      ];
    };
  };

  volumes = {
    umami_db_data = { name = "umami_db_data"; };
    umami_config  = { name = "umami_config"; };
  };
}
