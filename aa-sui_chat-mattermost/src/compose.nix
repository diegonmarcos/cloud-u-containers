# compose.nix — docker-compose spec for mattermost-bots.
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
#
# Three services share the VM network (network_mode: host):
#   mattermost         — team-chat UI/API (wraps upstream via binariesImage)
#   postgres           — database (upstream image directly)
#   mattermost-bots    — ntfy bridge + C3 slash-command bot (python upstream
#                        + assets/ntfy-bridge.py mounted from dist/assets/)
#
# ntfy-topics are read verbatim from ./ntfy-topics.nix (declarative list).
{ buildJson, container, base_domain, ntfyTopics }:

let
  app   = buildJson.containers.app;    # mattermost
  db    = buildJson.containers.db;     # postgres
  bots  = buildJson.containers.bots;   # python bridge

  svc = container.services;

  # Engine emits dist/code/<arch>/Dockerfile (wraps buildJson.containers.app.image
  # by default) and ships it to GHCR as <name>-binaries:latest. The mattermost
  # container pulls this image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # db_name/db_user come from build.json
  dbName = db.db_name;
  dbUser = db.db_user;

  # Runtime WG addressing (from cloud-data via container.services) and ports
  selfWgIp   = svc."mattermost-bots".ip;          # VM WG IP for this service
  appPort    = buildJson.ports.app;
  dbPort     = buildJson.ports.db;
  c3Port     = buildJson.c3.port;
  c3ApiUrl   = buildJson.c3.api_url;
  ollamaUrl  = "http://${svc.ollama.ip}:${toString svc.ollama.ports.app}";
  ollamaModel = buildJson.ollama.model;
  ollamaVm    = svc.ollama.vm;
  ntfyUrl    = "http://${svc.ntfy.ip}:${toString svc.ntfy.ports.app}";
  topicsCsv  = builtins.concatStringsSep "," ntfyTopics;
in
{
  services = {
    mattermost = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      command = "mattermost server";
      env_file = [ ".secrets" ];
      environment = {
        TZ = buildJson.timezone;
        MM_SQLSETTINGS_DRIVERNAME                            = "postgres";
        MM_SERVICESETTINGS_SITEURL                           = "https://${buildJson.domain}";
        MM_PLUGINSETTINGS_ENABLEUPLOADS                      = "true";
        MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS            = "true";
        MM_SERVICESETTINGS_ENABLECOMMANDS                    = "true";
        MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION          = "true";
        MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS            = "true";
        MM_DISPLAYSETTINGS_EXPERIMENTALTIMEZONE              = "true";
        MM_LOCALIZATIONSETTINGS_DEFAULTCLIENTLOCALE          = "en";
        MM_DISPLAYSETTINGS_CLOCKFORMAT                       = "24h";
        MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS = "localhost";
        MM_SERVICESETTINGS_LISTENADDRESS                     = ":${toString appPort}";
      };
      volumes = [
        "mattermost_config:/mattermost/config"
        "mattermost_data:/mattermost/data"
        "mattermost_logs:/mattermost/logs"
        "mattermost_plugins:/mattermost/plugins"
        "mattermost_client_plugins:/mattermost/client/plugins"
      ];
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
      env_file = [ ".secrets" ];
      environment = {
        POSTGRES_DB   = dbName;
        POSTGRES_USER = dbUser;
        PGPORT        = toString dbPort;
      };
      volumes = [ "mattermost_postgres:/var/lib/postgresql/data" ];
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U ${dbUser} -d ${dbName}" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };

    mattermost-bots = {
      image = bots.image;                     # python:3.12-slim (upstream)
      container_name = bots.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      # Mount the bridge script + requirements from dist/assets/ (engine copies
      # them there via extraAssets in flake.nix).
      volumes = [
        "./assets/ntfy-bridge.py:/app/ntfy-bridge.py:ro"
        "./assets/requirements-bridge.txt:/app/requirements.txt:ro"
      ];
      entrypoint = [
        "/bin/sh" "-c"
        "pip install --quiet -r /app/requirements.txt && python /app/ntfy-bridge.py"
      ];
      environment = {
        NTFY_URL                        = ntfyUrl;
        TOPICS                          = topicsCsv;
        MM_URL                          = "http://localhost:${toString appPort}";
        C3_API_URL                      = c3ApiUrl;
        C3_BIND_IP                      = selfWgIp;
        C3_PORT                         = toString c3Port;
        C3_ACTION_URL                   = "http://mattermost-bots:${toString c3Port}/c3/action";
        C3_SLASH_URL                    = "http://mattermost-bots:${toString c3Port}/c3";
        OLLAMA_URL                      = ollamaUrl;
        OLLAMA_MODEL                    = ollamaModel;
        OLLAMA_VM                       = ollamaVm;
        AUTHELIA_OIDC_CLIENT_ID         = "mattermost-cc";
        AUTHELIA_OIDC_CLIENT_SECRET     = "\${AUTHELIA_OIDC_MATTERMOST_SECRET}";
        AUTHELIA_TOKEN_URL              = "https://auth.${base_domain}/api/oidc/token";
      };
      depends_on.mattermost = { condition = "service_started"; };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };

  volumes = {
    mattermost_config         = {};
    mattermost_data           = {};
    mattermost_logs           = {};
    mattermost_plugins        = {};
    mattermost_client_plugins = {};
    mattermost_postgres       = {};
  };
}
