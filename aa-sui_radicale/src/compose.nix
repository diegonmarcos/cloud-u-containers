# compose.nix — docker-compose spec for radicale (Type B wrap-upstream).
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service. Paths are relative to dist/
# (docker-compose project-directory at deploy time).
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    radicale = {
      image = binariesImage;
      container_name = app.container_name;
      ports = [ "${svc.radicale.ip}:${toString buildJson.ports.app}:${toString buildJson.ports.app}" ];
      networks = [ "default" ];
      volumes = [
        "radicale_data:/data"
        "./configs/config:/config/config:ro"
      ];
      environment = {
        TAKE_FILE_OWNERSHIP = "true";
      };
      healthcheck = {
        test = [ "CMD-SHELL" "curl -f http://localhost:${toString buildJson.ports.app}/.web/ || exit 1" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
      deploy.resources = {
        limits       = { memory = "256M"; cpus = "1.0"; };
        reservations = { memory = "32M"; };
      };
    };
  };
  volumes = {
    radicale_data = {};
  };
  networks = {
    default = {};
  };
}
