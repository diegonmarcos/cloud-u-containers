# compose.nix — docker-compose spec for filebrowser (Type B, wrap upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
{ buildJson, container }:

let
  svc           = container.services;
  app           = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    filebrowser = {
      image          = binariesImage;
      container_name = app.container_name;
      ports = [
        "${svc.filebrowser.ip}:${toString buildJson.ports.app}:8080"
      ];
      dns = [ svc.filebrowser.ip ];
      volumes = [
        "filebrowser_data:/srv"
        "filebrowser_db:/database"
        "filebrowser_config:/config"
      ];
      environment = {
        PUID        = "1000";
        PGID        = "1000";
        FB_DATABASE = "/database/filebrowser.db";
        FB_CONFIG   = "/config/settings.json";
        FB_ROOT     = "/srv";
        FB_NOAUTH   = "false";
        FB_LOG      = "stdout";
        FB_PORT     = "8080";
      };
      healthcheck = {
        test     = [ "CMD" "wget" "-q" "--spider" "http://localhost:8080/health" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
    };
  };
  volumes = {
    filebrowser_data   = {};
    filebrowser_db     = {};
    filebrowser_config = {};
  };
}
