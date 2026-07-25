# compose.nix — docker-compose for hermes-agent.
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY gateway: host network so the container can reach the WireGuard mesh
# (claude-superset-api at 10.0.0.6:3117) and make outbound Telegram egress
# without NAT hairpin issues. No inbound HTTP port is published — the Hermes
# API server is NOT enabled (command = ["gateway" "run"] only), so there is
# nothing to expose. public:false, no Caddy route.
#
# AUTH: secrets delivered via .secrets env_file (sops-encrypted src/secrets.yaml
# → dist/.secrets at deploy). Contains TELEGRAM_BOT_TOKEN, OPENAI_API_KEY
# (pointed at claude-superset-api), and MATTERMOST_TOKEN.
#
# Tunables are data-driven from build.json `runtime` (no hardcoded data in the
# engine): changing the model or backend_url is a JSON edit.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  rt  = buildJson.runtime or {};
in
{
  services = {
    hermes-agent = {
      image          = "nousresearch/hermes-agent:latest";
      container_name = app.container_name;
      # host networking: reach WG mesh (10.0.0.6) + outbound Telegram without NAT.
      network_mode   = "host";
      command        = [ "gateway" "run" ];
      # Secrets: TELEGRAM_BOT_TOKEN, OPENAI_API_KEY, MATTERMOST_TOKEN.
      env_file       = [ "./.secrets" ];
      environment    = {
        HERMES_UID           = "10000";
        HERMES_GID           = "10000";
        TZ                   = buildJson.timezone or "Europe/Berlin";
        TELEGRAM_ALLOWED_USERS = "6431508617";
        # Point the OpenAI-compat client at claude-superset-api over WG.
        OPENAI_BASE_URL      = rt.backend_url or "http://10.0.0.6:3117/v1";
        OPENAI_MODEL         = rt.model or "claude-sonnet-4-6";
      };
      volumes = [
        "hermes_data:/opt/data"
        # Declarative config overlay (read-only); operator writes configs/config.yaml.
        "./configs/config.yaml:/opt/data/config.yaml:ro"
      ];
      # NO healthcheck: the Hermes gateway subcommand exposes no HTTP health
      # endpoint when the API server is disabled (command = "gateway run").
      # Enable once the api-server subcommand is added and a port is opened.
    };
  };

  # Named volume for persistent agent memory, conversation history, and state.
  volumes = {
    hermes_data = { name = "hermes-agent-data"; };
  };
}
