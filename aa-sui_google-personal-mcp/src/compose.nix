# compose.nix — docker-compose spec for google-personal-mcp
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  port = toString buildJson.ports.app;
in
{
  services = {
    google-personal-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        PORT = port;
        MCP_HTTP_PORT = port;
        IMAP_HOST = buildJson.auth.imap_host;
        IMAP_PORT = toString buildJson.auth.imap_port;
        SMTP_HOST = buildJson.auth.smtp_host;
        SMTP_PORT = toString buildJson.auth.smtp_port;
      };
      healthcheck = {
        test = [
          "CMD"
          "curl"
          "-f"
          "http://localhost:${port}/health"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
}
