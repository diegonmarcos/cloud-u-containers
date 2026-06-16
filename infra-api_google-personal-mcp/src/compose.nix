# compose.nix — docker-compose spec for google-personal-mcp
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  port = toString buildJson.ports.app;
  # WG IP from cloud-data — host-network mode binds the MCP listener to the
  # WG mesh only, never 0.0.0.0. Pattern matches sibling MCP composes.
  vmIp = svc."google-personal-mcp".ip or "10.0.0.6";
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
        MCP_HTTP_HOST = vmIp;
        HOST = vmIp;
        IMAP_HOST = buildJson.auth.imap_host;
        IMAP_PORT = toString buildJson.auth.imap_port;
        SMTP_HOST = buildJson.auth.smtp_host;
        SMTP_PORT = toString buildJson.auth.smtp_port;
      };
      healthcheck = {
        test = [
          "CMD" "node" "-e"
          "fetch('http://${vmIp}:${port}/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
}
