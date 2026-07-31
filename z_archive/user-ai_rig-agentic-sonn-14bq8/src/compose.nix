# compose.nix — docker-compose spec for rig-agentic-sonn-14bq8 (Type A, own code)
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  selfSvc       = svc.${buildJson.name};
  ollamaSvc     = svc.${buildJson.rig.ollama_service};
  mattermostSvc = svc.${buildJson.rig.mattermost_service};

  ollamaUrl     = "http://${ollamaSvc.ip}:${toString ollamaSvc.ports.app}";
  mattermostUrl = "http://${mattermostSvc.ip}:${toString mattermostSvc.ports.app}";
  rigHost       = selfSvc.ip;
  rigPort       = toString app.port;
in
{
  services = {
    "rig-agentic-sonn-14bq8" = {
      image = binariesImage;
      container_name = app.container_name;
      restart = "no";
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        RIG_HOST = rigHost;
        RIG_PORT = rigPort;
        OLLAMA_URL = ollamaUrl;
        OLLAMA_API_BASE_URL = ollamaUrl;
        OLLAMA_MODEL = buildJson.rig.ollama_model;
        C3_API_URL = buildJson.rig.c3_api_url;
        C3_MCP_URL = buildJson.rig.c3_mcp_url;
        MATTERMOST_URL = mattermostUrl;
        GUARDRAIL_MAX_TURNS = toString buildJson.rig.guardrail_max_turns;
        GUARDRAIL_DENIED_TOOLS = "";
        GUARDRAIL_ALLOWED_TOOLS = "";
        SELF_HEALING_ENABLED =
          if buildJson.rig.self_healing_enabled then "true" else "false";
        MM_BOT_MENTION = buildJson.rig.mm_bot_mention;
        RUST_LOG = buildJson.rig.rust_log;
      };
      volumes = [ "/var/run/docker.sock:/var/run/docker.sock:ro" ];
      healthcheck = {
        test = [ "CMD" "curl" "-sf" "http://${rigHost}:${rigPort}/health" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
}
