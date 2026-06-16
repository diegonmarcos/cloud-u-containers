# compose.nix — docker-compose spec for code-server (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    code-server = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      # compose-defaults.json sets init: true (tini as PID 1), but the
      # linuxserver.io code-server image runs s6-overlay, which fatals with
      # "s6-overlay-suexec: fatal: can only run as pid 1" when tini owns PID 1
      # → container exits 100. Disable docker-init so s6 is PID 1.
      init = false;
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
