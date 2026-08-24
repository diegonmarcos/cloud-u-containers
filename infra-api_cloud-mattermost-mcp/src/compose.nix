# compose.nix — docker-compose spec for cloud-mattermost-mcp (Type A own-code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."cloud-mattermost-mcp".ip or "10.0.0.6";
  port = toString buildJson.ports.app;
in
{
  services = {
    cloud-mattermost-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      restart = "no";  # container-init handles startup
      ports = [ "${vmIp}:${port}:${port}" ];
      env_file = [ ".secrets" ];
      environment = {
        MCP_HTTP_PORT = port;
      };
    };
  };
}
