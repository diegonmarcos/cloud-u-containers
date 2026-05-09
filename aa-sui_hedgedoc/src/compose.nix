# compose.nix — pure attrset describing docker-compose.yml for hedgedoc.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
# Multi-container: app (hedgedoc) + db (postgres).
{ buildJson, container, containerDb }:

let
  svc = container.services;
  app = buildJson.containers.app;
  db  = buildJson.containers.db;

  # Published binaries image produced by the ship engine from code/<arch>/Dockerfile
  appImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  dbImage  = "ghcr.io/diegonmarcos/${buildJson.name}-db-binaries:latest";

  dbUser = containerDb.container.db_user;
  dbName = containerDb.container.db_name;
  dbPort = toString buildJson.ports.db;
  appPort = toString buildJson.ports.app;
in
{
  services = {
    hedgedoc = {
      image = appImage;
      container_name = app.container_name;
      # Tier-3 wg-only bind: data-driven IP from container.services.<self>.ip
      # (cloud-data-config-derive emits svc.<name>.ip per VM WG address).
      ports = [
        "${svc.hedgedoc.ip}:${appPort}:${appPort}"
      ];
      volumes = [
        "hedgedoc_uploads:/hedgedoc/public/uploads"
      ];
      environment = {
        CMD_PORT                  = appPort;
        CMD_DOMAIN                = buildJson.domain;
        CMD_URL_ADDPORT           = "false";
        CMD_PROTOCOL_USESSL       = "true";
        CMD_DB_URL                = "postgres://${dbUser}:${dbUser}@localhost:${dbPort}/${dbName}";
        CMD_ALLOW_EMAIL_REGISTER  = "true";
        CMD_EMAIL                 = "true";
        CMD_ALLOW_FREEURL         = "true";
        CMD_ALLOW_ANONYMOUS       = "true";
        CMD_ALLOW_ANONYMOUS_EDITS = "true";
        CMD_DEFAULT_PERMISSION    = "freely";
        CMD_SESSION_SECRET        = "\${CMD_SESSION_SECRET:-hedgedoc-secret-change-me}";
        CMD_TRUST_PROXY           = "true";
        CMD_LOGLEVEL              = "info";
      };
      depends_on.postgres = { condition = "service_healthy"; };
    };
    postgres = {
      image = dbImage;
      container_name = db.container_name;
      volumes = [
        "postgres_data:/var/lib/postgresql/data"
      ];
      environment = {
        POSTGRES_USER     = dbUser;
        POSTGRES_PASSWORD = dbUser;
        POSTGRES_DB       = dbName;
        PGDATA            = "/var/lib/postgresql/data/pgdata";
        PGPORT            = dbPort;
      };
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U ${dbUser} -p ${dbPort}" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
    };
  };
  volumes = {
    hedgedoc_uploads = {};
    postgres_data = {};
  };
}
