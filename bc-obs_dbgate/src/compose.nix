# compose.nix — pure attrset describing docker-compose.yml for dbgate.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Per-database env vars (LABEL_*, SERVER_*, PORT_*, USER_*, PASSWORD_*,
# ENGINE_*, DATABASE_*, READONLY_*) are generated programmatically from
# the resolved cloud-data-databases.json (bundled at /app/ in-image, with
# dist/ + legacy fallbacks resolved by flake.nix) and folded into
# services.dbgate.environment.
{ lib, buildJson, container, dbData }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # ── Database discovery (data-driven) ──────────────────────────────
  # Keep only connectable engines with exposed ports; skip self + archived.
  connectable = builtins.filter (db:
    db.enabled
    && db.port != null
    && (db.type == "postgres" || db.type == "mariadb")
    && db.service != "dbgate"
    && db.service != "nocodb"
  ) dbData.databases;

  # Safe env-var suffix: replace hyphens with underscores
  mkId = service: builtins.replaceStrings ["-"] ["_"] service;

  # DBGate engine string per DB type
  engineFor = type:
    if type == "postgres" then "postgres@dbgate-plugin-postgres"
    else if type == "mariadb" then "mysql@dbgate-plugin-mysql"
    else "unknown";

  # Same-VM → localhost, else WG IP
  # container.vm is the alias (e.g. "oci-apps"); cloud-data now stores
  # hardware names in db.vm with the alias under db.vm_alias, so prefer
  # vm_alias when present for the comparison.
  dbgateVm = container.vm;
  hostFor = db:
    let dbVm = db.vm_alias or db.vm; in
    if dbVm == dbgateVm then "localhost" else db.wg_ip;

  # One attrset of env-var lines for a single DB
  mkDbEnv = db: let
    id = mkId db.service;
    user = db.user or "postgres";
    dbName = db.db or db.service;
    vmLabel = db.vm_alias or db.vm;
  in {
    "LABEL_${id}"    = "${db.service} (${db.type} @ ${vmLabel})";
    "SERVER_${id}"   = hostFor db;
    "PORT_${id}"     = toString db.port;
    "USER_${id}"     = user;
    # Docker-compose variable interpolation — secrets.escape_dollars: true
    # in build.json doubles $ → $$ so the final file keeps "${PASSWORD_…}".
    "PASSWORD_${id}" = "\${PASSWORD_${id}}";
    "ENGINE_${id}"   = engineFor db.type;
    "DATABASE_${id}" = dbName;
    "READONLY_${id}" = "1";
  };

  connectionIds = map (db: mkId db.service) connectable;
  connectionsStr = lib.concatStringsSep "," connectionIds;

  # Merge every DB block into one flat env attrset
  allDbEnvs = lib.foldl' (acc: db: acc // mkDbEnv db) {} connectable;

  baseEnv = {
    PORT        = toString buildJson.ports.app;
    TZ          = buildJson.timezone;
    CONNECTIONS = connectionsStr;
  };

in
{
  services = {
    dbgate = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = baseEnv // allDbEnvs;
      volumes = [ "dbgate_data:/root/.dbgate" ];
      healthcheck = {
        test = [
          "CMD" "wget" "-q" "--spider"
          "http://localhost:${toString buildJson.ports.app}/"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
  };
  volumes = {
    dbgate_data = { name = "dbgate_data"; };
  };
}
