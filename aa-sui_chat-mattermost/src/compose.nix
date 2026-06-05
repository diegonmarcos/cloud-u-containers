# compose.nix — docker-compose spec for chat-mattermost.
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
  selfWgIp   = svc."chat-mattermost".ip;          # VM WG IP for this service
  appPort    = buildJson.ports.app;
  dbPort     = buildJson.ports.db;
  c3Port     = buildJson.c3.port;
  c3ApiUrl   = buildJson.c3.api_url;
  # Ollama service was renamed: cluster cloud-data now exposes "ollama-hai"
  # (the Haiku-tier Ollama runner on oci-apps-2) instead of plain "ollama".
  # Quoted lookup because hyphens aren't valid Nix attr-path bare identifiers.
  ollamaUrl  = "http://${svc."ollama-hai".ip}:${toString svc."ollama-hai".ports.app}";
  ollamaModel = buildJson.ollama.model;
  ollamaVm    = svc."ollama-hai".vm;
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
        MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS = "localhost,${selfWgIp}";
        # WG-bind ONLY: explicit interface binding to the wg0 mesh IP for this
        # service. Was `:${appPort}` (all interfaces — including the oci-apps
        # public IP). Now only the WG mesh can reach the chat container; public
        # traffic must come through Caddy on gcp-proxy → WG tunnel → here.
        # Per feedback `feedback_ssh_wg_only.md` extended to app-port binds.
        MM_SERVICESETTINGS_LISTENADDRESS                     = "${selfWgIp}:${toString appPort}";

        # ── Stage 3: SMTP / email notifications via Stalwart ────────────────
        # FROM address is me@diegonmarcos.com (Stalwart-hosted mailbox).
        # Server is the Stalwart SMTPS endpoint on oci-mail (port 2465 is
        # the host-mapped form of container port 465 — implicit TLS).
        # MM_EMAILSETTINGS_SMTPPASSWORD lives in src/secrets.yaml (sops);
        # provision the me@ account password in Stalwart admin first, then
        # `sops src/secrets.yaml` and add the encrypted value.
        MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS              = "true";
        MM_EMAILSETTINGS_FEEDBACKEMAIL                       = "me@diegonmarcos.com";
        MM_EMAILSETTINGS_FEEDBACKNAME                        = "Mattermost";
        MM_EMAILSETTINGS_REPLYTOADDRESS                      = "me@diegonmarcos.com";
        MM_EMAILSETTINGS_SMTPSERVER                          = "smtp.diegonmarcos.com";
        MM_EMAILSETTINGS_SMTPPORT                            = "2465";
        MM_EMAILSETTINGS_CONNECTIONSECURITY                  = "TLS";
        MM_EMAILSETTINGS_SMTPUSERNAME                        = "me@diegonmarcos.com";
        MM_EMAILSETTINGS_SKIPSERVERCERTIFICATEVERIFICATION   = "false";
        MM_EMAILSETTINGS_ENABLESMTPAUTH                      = "true";

        # ── Stage 4: Agents plugin (from mattermost/mattermost-plugin-agents) ─
        # Plugin ID is `mattermost-ai` (verified from v2.3.0 plugin.json).
        # Mattermost converts dots/hyphens in plugin IDs to underscores and
        # uppercases for env-var lookup. The env-var keys below are the
        # cleaned-up versions of the original com.mattermost.agents naming
        # I used by mistake in earlier commits (those env vars were silent
        # no-ops because the plugin ID didn't match).
        #
        # Plugin enable via env-var override of config.json:
        #   PluginSettings.PluginStates["mattermost-ai"].Enable
        MM_PLUGINSETTINGS_PLUGINSTATES_MATTERMOST_AI_ENABLE = "true";

        # MCP server registration via env-var override of:
        #   PluginSettings.Plugins["mattermost-ai"].mcpservers
        # The plugin's settings_schema declares a `Config` field of type
        # "custom" — meaning the System Console UI is a React panel rather
        # than standard form fields. Whether Mattermost's env-var → nested
        # plugin-config mapping accepts a JSON-encoded array here is
        # unverified on v2.3.0 + TE 11.8-rc5. If it doesn't bind, the same
        # six entries can be added in System Console → Plugins → Agents.
        # Either way the data is declared in source.
        #
        # Bearer token interpolation: docker compose substitutes ${VAR}
        # from the project shell env / a .env file in the project dir at
        # compose-up time. .secrets (env_file) is NOT visible to this
        # substitution — it's runtime-only inside the container. The
        # current shape will resolve to literal "Bearer " (empty) until
        # BEARER_TOKEN is exposed at compose-parse time. Tracked as a
        # follow-up; the env-var path may not even take effect first.
        MM_PLUGINSETTINGS_PLUGINS_MATTERMOST_AI_MCPSERVERS = builtins.toJSON [
          { name = "cloud-infra";      url = "https://mcp.${base_domain}/c3-infra-mcp/mcp";    headers = { Authorization = "Bearer \${BEARER_TOKEN}"; }; }
          { name = "cloud-services";   url = "https://mcp.${base_domain}/c3-services-mcp/mcp"; headers = { Authorization = "Bearer \${BEARER_TOKEN}"; }; }
          { name = "mattermost";       url = "https://mcp.${base_domain}/mattermost-mcp/mcp";  headers = { Authorization = "Bearer \${BEARER_TOKEN}"; }; }
          { name = "mail-mcp";         url = "https://mcp.${base_domain}/mail-mcp/mcp";        headers = { Authorization = "Bearer \${BEARER_TOKEN}"; }; }
          { name = "google-workspace"; url = "https://mcp.${base_domain}/g-workspace/mcp";     headers = { Authorization = "Bearer \${BEARER_TOKEN}"; }; }
          { name = "google-personal";  url = "https://mcp.${base_domain}/g-personal/mcp";      headers = { Authorization = "Bearer \${BEARER_TOKEN}"; }; }
        ];
        MM_PLUGINSETTINGS_PLUGINS_MATTERMOST_AI_MCPENABLED = "true";
      };
      volumes = [
        "mattermost_config:/mattermost/config"
        "mattermost_data:/mattermost/data"
        "mattermost_logs:/mattermost/logs"
        # Plugin volumes are mounted (so System Console "Install Plugin"
        # uploads persist across restarts). The agents plugin is baked
        # into the image at /mattermost/plugins/mattermost-ai/; docker
        # auto-populates a named volume from the image ONLY on first
        # creation. Empty pre-existing volumes (from the Stage 2
        # migration that cp -a'd empty plugin dirs over) shadow the
        # image content, so the migration pre_hook now also drops the
        # empty plugin volumes once → next compose-up auto-populates
        # them from the image. See migrate-from-mattermost-bots.sh:
        # section 4 + marker .plugin-volumes-seeded.
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
        # Mattermost now listens on ${selfWgIp}:${appPort} (WG-bind ONLY), so
        # the bots service must reach it via the WG IP too — localhost no
        # longer carries an mm listener.
        MM_URL                          = "http://${selfWgIp}:${toString appPort}";
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
