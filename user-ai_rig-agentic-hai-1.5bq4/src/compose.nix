# compose.nix — docker-compose spec for rig-agentic-hai (Type A, own code)
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  ollamaSvc = svc.${buildJson.rig.ollama_service};
  ollamaUrl = "http://localhost:${toString ollamaSvc.ports.app}";

  rigHost = svc.${buildJson.name}.ip;
  rigPort = toString app.port;

  allowedTools = builtins.concatStringsSep "," buildJson.rig.allowed_tools;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    rig-agentic-hai = {
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
        C3_MCP_URL = buildJson.rig.c3_mcp_url;
        MATTERMOST_URL = buildJson.rig.mattermost_url;
        GUARDRAIL_MAX_TURNS = toString buildJson.rig.guardrail_max_turns;
        GUARDRAIL_DENIED_TOOLS = "";
        GUARDRAIL_ALLOWED_TOOLS = allowedTools;
        SELF_HEALING_ENABLED =
          if buildJson.rig.self_healing_enabled then "true" else "false";
        MM_BOT_MENTION = buildJson.rig.mm_bot_mention;
        RUST_LOG = buildJson.rig.rust_log;
      };
      healthcheck = {
        test = [ "CMD" "curl" "-sf" "http://localhost:${rigPort}/health" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
}
