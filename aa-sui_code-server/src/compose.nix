# compose.nix — docker-compose spec for code-server (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  # WG-bind from cloud-data — engine-resolved (resolveBindHost in
  # 2_configs/src/engines/cloud-data-config-derive.ts).
  bindHost = container.bind_host;
  appPort = toString buildJson.ports.app;
in
{
  services = {
    code-server = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      # Bind code-server to WG IP only — no public 0.0.0.0 listener.
      command = [ "--bind-addr" "${bindHost}:${appPort}" ];
      environment = {
        TZ = buildJson.timezone;
        PUID = "1000";
        PGID = "1000";
        DEFAULT_WORKSPACE = "/workspace";
      };
      volumes = [
        "code_server_config:/config"
        "/home/ubuntu/workspace:/workspace"
      ];
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };
  volumes = {
    code_server_config = {};
  };
}
