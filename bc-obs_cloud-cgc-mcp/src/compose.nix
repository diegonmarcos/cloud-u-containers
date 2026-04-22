# compose.nix — pure attrset describing docker-compose.yml for cloud-cgc-mcp.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Single service: cloud-cgc-mcp — Code Graph Context MCP server
#   - Own code (Type A) packaged by ship engine via native_build.type=image-wrapper
#   - HTTP + stdio transports; host network so Caddy can reach it at 127.0.0.1:PORT
#   - Reads CONFIG_PATH (points at /data/config.json, with sibling cloud-data/)
{ buildJson, container }:

let
  app = buildJson.containers.app;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    cloud-cgc-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        MCP_TRANSPORT  = "http";
        MCP_HTTP_PORT  = toString buildJson.ports.app;
        CONFIG_PATH    = "${buildJson.runtime.data_path}/config.json";
        GIT_ROOT       = buildJson.runtime.git_root;
      };
      volumes = [
        "./data:${buildJson.runtime.data_path}:ro"
      ];
      healthcheck = {
        test = [
          "CMD" "node" "-e"
          "fetch('http://localhost:${toString buildJson.ports.app}${app.healthcheck}').catch(()=>process.exit(1))"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "15s";
      };
    };
  };
}
