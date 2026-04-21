# compose.nix — docker-compose spec for dozzle (Type B, wrap upstream)
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
    dozzle = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      environment = {
        DOZZLE_LEVEL = "info";
        DOZZLE_ADDR  = "${svc.dozzle.ip}:${toString buildJson.ports.app}";
      };
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:ro"
      ];
      deploy.resources = {
        limits       = { memory = "64M"; cpus = "1.0"; };
        reservations = { memory = "16M"; };
      };
    };
  };
}
