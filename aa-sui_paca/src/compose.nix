# compose.nix — docker-compose spec for Paca (core stack, no MinIO / no ai-agent).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json (init/logging/ulimits/security_opt/pids) into
# every service.
#
# Networking: a dedicated `paca-net` bridge (authelia pattern). Service KEYS are
# Paca's upstream names (postgres/valkey/api/web/realtime/gateway) because the
# bundled nginx gateway.conf resolves upstreams by those bare names via Docker
# DNS (resolver 127.0.0.11). container_name adds a second alias (paca-*). Only
# the gateway publishes a host port (buildJson.ports.gateway → :80), reached by
# Caddy over the WG mesh; the paca.diegonmarcos.com route is WG-only (fail-closed
# default).
#
# Storage: MinIO dropped — STORAGE_PROVIDER=s3 against OCI Object Storage.
# STORAGE_ENDPOINT + access keys come from .secrets (sops). Bucket "paca" must
# exist. NOTE: gateway.conf's /storage/ → minio block must be repointed to S3 or
# removed (the SPA fetches assets from STORAGE_PUBLIC_URL).
#
# Secrets (src/secrets.yaml → .secrets env_file): POSTGRES_PASSWORD, JWT_SECRET,
# ADMIN_PASSWORD, ENCRYPTION_KEY, STORAGE_ENDPOINT, STORAGE_ACCESS_KEY_ID,
# STORAGE_SECRET_ACCESS_KEY. escape_dollars=true (compose ${VAR} in DATABASE_URL).
{ buildJson, container, base_domain }:

let
  c          = buildJson.containers;
  domain     = buildJson.domain;
  publicUrl  = "https://${domain}";
  gwPort     = toString buildJson.ports.gateway;
  dbUser     = c.db.db_user;
  dbName     = c.db.db_name;
  # ${POSTGRES_PASSWORD} interpolated at compose-up from --env-file (.secrets);
  # escape_dollars=true keeps it literal through secrets substitution.
  databaseUrl = "postgres://${dbUser}:\${POSTGRES_PASSWORD}@postgres:5432/${dbName}?sslmode=disable";
  redisUrl    = "redis://valkey:6379/0";
  mem = m: c': { deploy.resources = { limits = m; reservations = c'; }; };
in
{
  services = {
    postgres = {
      image = c.db.image;
      container_name = c.db.container_name;
      networks = [ "paca-net" ];
      restart = "unless-stopped";
      env_file = [ ".secrets" ];
      environment = { POSTGRES_DB = dbName; POSTGRES_USER = dbUser; };
      volumes = [ "paca_postgres:/var/lib/postgresql/data" ];
      healthcheck = { test = [ "CMD-SHELL" "pg_isready -U ${dbUser} -d ${dbName}" ]; interval = "10s"; timeout = "5s"; retries = 10; };
      deploy.resources = { limits = { memory = "512M"; cpus = "1.0"; }; reservations = { memory = "64M"; }; };
    };

    valkey = {
      image = c.valkey.image;
      container_name = c.valkey.container_name;
      networks = [ "paca-net" ];
      restart = "unless-stopped";
      command = "valkey-server --appendonly yes";
      volumes = [ "paca_valkey:/data" ];
      healthcheck = { test = [ "CMD" "valkey-cli" "ping" ]; interval = "10s"; timeout = "5s"; retries = 10; };
      deploy.resources = { limits = { memory = "256M"; cpus = "0.5"; }; reservations = { memory = "32M"; }; };
    };

    api = {
      image = c.api.image;
      container_name = c.api.container_name;
      networks = [ "paca-net" ];
      restart = "unless-stopped";
      env_file = [ ".secrets" ];
      environment = {
        ENV                     = "production";
        PORT                    = "8080";
        DATABASE_URL            = databaseUrl;
        REDIS_URL               = redisUrl;
        JWT_ACCESS_TTL          = "15m";
        JWT_REFRESH_TTL         = "168h";
        JWT_REFRESH_SESSION_TTL = "24h";
        COOKIE_SECURE           = "true";
        ADMIN_USERNAME          = "admin";
        STORAGE_PROVIDER        = "s3";
        STORAGE_REGION          = "eu-marseille-1";
        STORAGE_BUCKET          = "paca";
        STORAGE_USE_SSL         = "true";
        STORAGE_PUBLIC_URL      = "${publicUrl}/storage";
        PUBLIC_URL              = publicUrl;
        PLUGINS_WASM_DIR        = "/plugins";
        PLUGINS_FRONTEND_DIR    = "/plugins-frontend";
        PLUGINS_MCP_DIR         = "/plugins-mcp";
      };
      volumes = [
        "paca_backend_plugins:/plugins"
        "paca_frontend_plugins:/plugins-frontend"
        "paca_mcp_plugins:/plugins-mcp"
      ];
      depends_on = {
        postgres.condition = "service_healthy";
        valkey.condition   = "service_healthy";
      };
      healthcheck = { test = [ "CMD" "wget" "-q" "--spider" "http://localhost:8080/api/healthz" ]; interval = "10s"; timeout = "5s"; retries = 10; start_period = "40s"; };
      deploy.resources = { limits = { memory = "768M"; cpus = "1.0"; }; reservations = { memory = "128M"; }; };
    };

    web = {
      image = c.web.image;
      container_name = c.web.container_name;
      networks = [ "paca-net" ];
      restart = "unless-stopped";
      depends_on.api.condition = "service_started";
      deploy.resources = { limits = { memory = "128M"; cpus = "0.5"; }; reservations = { memory = "16M"; }; };
    };

    realtime = {
      image = c.realtime.image;
      container_name = c.realtime.container_name;
      networks = [ "paca-net" ];
      restart = "unless-stopped";
      environment = {
        PORT         = "3001";
        NODE_ENV     = "production";
        API_URL      = "http://api:8080";
        REDIS_URL    = redisUrl;
        CORS_ORIGINS = publicUrl;
        LOG_LEVEL    = "info";
      };
      depends_on = {
        valkey.condition = "service_healthy";
        api.condition    = "service_healthy";
      };
      deploy.resources = { limits = { memory = "256M"; cpus = "0.5"; }; reservations = { memory = "32M"; }; };
    };

    gateway = {
      image = c.gateway.image;
      container_name = c.gateway.container_name;
      networks = [ "paca-net" ];
      restart = "unless-stopped";
      # Only published port. oci-apps host firewall blocks public ingress
      # (collapsed surface); Caddy reaches :${gwPort} over WG and WG-gates the
      # paca.diegonmarcos.com route (fail-closed default).
      ports = [ "${gwPort}:80" ];
      volumes = [ "./assets/gateway.conf:/etc/nginx/conf.d/default.conf:ro" ];
      depends_on = {
        api.condition      = "service_started";
        web.condition      = "service_started";
        realtime.condition = "service_started";
      };
      deploy.resources = { limits = { memory = "128M"; cpus = "0.5"; }; reservations = { memory = "16M"; }; };
    };
  };

  networks = { paca-net = { driver = "bridge"; }; };

  volumes = {
    paca_postgres         = {};
    paca_valkey           = {};
    paca_backend_plugins  = {};
    paca_frontend_plugins = {};
    paca_mcp_plugins      = {};
  };
}
