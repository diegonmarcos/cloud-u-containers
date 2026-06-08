# compose.nix — docker-compose spec (Type B wrap-upstream).
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service. Paths are relative to dist/
# (docker-compose project-directory at deploy time).
#
# Data-driven: service key + container_name + bind-mount volumes all come
# from buildJson.containers.app. No hardcoded service names, no named
# docker volumes — bind-mounts on the host fs.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  ownIp         = svc."${buildJson.name}".ip;
  appPort       = toString buildJson.ports.app;
in
{
  services = {
    "${app.container_name}" = {
      image = binariesImage;
      container_name = app.container_name;
      ports = [ "${ownIp}:${appPort}:${appPort}" ];
      networks = [ "default" ];
      volumes = app.volumes;
      environment = {
        TAKE_FILE_OWNERSHIP = "true";
      };
      healthcheck = {
        test = [ "CMD-SHELL" "curl -f http://localhost:${appPort}${app.healthcheck} || exit 1" ];
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
  networks = {
    default = {};
  };
}
