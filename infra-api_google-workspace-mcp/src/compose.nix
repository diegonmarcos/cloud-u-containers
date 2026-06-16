# compose.nix — docker-compose spec for google-workspace-mcp (Type A own-code, Python)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."google-workspace-mcp".ip or "10.0.0.6";
  port = toString buildJson.ports.app;
in
{
  services = {
    google-workspace-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        WORKSPACE_MCP_HOST = vmIp;
        WORKSPACE_MCP_PORT = port;
        PORT = port;
        USER_GOOGLE_EMAIL = buildJson.user_google_email;
        GOOGLE_SERVICE_ACCOUNT_KEY_PATH = "/run/secrets/service-account-key.json";
      };
      volumes = [
        "./.secrets.d/GOOGLE_SERVICE_ACCOUNT_KEY:/run/secrets/service-account-key.json:ro"
      ];
      healthcheck = {
        test = [
          "CMD"
          "curl"
          "-f"
          "http://${vmIp}:${port}/health"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
}
