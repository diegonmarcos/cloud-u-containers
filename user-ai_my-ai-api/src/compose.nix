# compose.nix — docker-compose for my-ai-api.
# WG-ONLY: host networking so the container reaches the WG mesh (10.0.0.6)
# for the claude-cli backend and makes outbound OpenRouter calls without NAT.
# Three process bindings on the host: 3217 (Node /v1), 12436 (Ollama mimic),
# 8890 (Headroom FastAPI sidecar). No Caddy route — public:false.
# Secrets via .secrets env_file (sops-decrypted OPENROUTER_API_KEY).
{ buildJson, container }:

let
  app   = buildJson.containers.app;
  rt    = buildJson.runtime or {};
  ports = buildJson.ports or {};
  gw = rt.gateway or {};
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    my-ai-api = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      env_file       = [ "./.secrets" ];
      environment    = {
        BRIDGE_PORT        = toString (ports.app      or 3217);
        OLLAMA_PORT        = toString (ports.ollama   or 12436);
        # wg0-only: bind the /v1 API + Ollama mimic to the WG address so WG-peer
        # GHA runners can reach them. localhost default left them unreachable over
        # wg0 (octocode LLM calls from the x86 runner silently failed). NOT 0.0.0.0
        # — 10.0.0.6 is the WG interface only, never a public bind.
        BRIDGE_BIND        = rt.wg_bind or "10.0.0.6";
        BRIDGE_OLLAMA_BIND = rt.wg_bind or "10.0.0.6";
        # In-container gateway (telegram/mattermost bot) calls the /v1 API. Follow
        # the wg0 bind — localhost no longer answers once BRIDGE_BIND is the WG IP.
        MYAI_LOCAL_URL     = "http://${rt.wg_bind or "10.0.0.6"}:3217";
        HEADROOM_PORT      = toString (ports.headroom or 8890);
        GOOSE_PORT         = toString (ports.goosed   or 3227);
        DEFAULT_MODEL      = rt.model or "z-ai/glm-5";
        MAX_CONCURRENCY    = toString (rt.max_concurrency or 12);
        CALL_TIMEOUT_MS    = toString (rt.call_timeout_ms or 180000);
        MATTERMOST_URL     = gw.mattermost_url     or "";
        MATTERMOST_ENABLED = gw.mattermost_enabled  or "false";
        TELEGRAM_ALLOW_FROM = gw.telegram_allow_from or "";
        MCP_ENABLED        = "1";
      };
      volumes = [
        "my_ai_home:/home/appuser"
      ];
      healthcheck = {
        test     = [ "CMD" "curl" "-sf" "http://10.0.0.6:3217/health" ];
        interval = "30s";
        timeout  = "5s";
        retries  = 3;
      };
    };
  };

  volumes = {
    my_ai_home = { name = "my-ai-api-home"; };
  };
}
