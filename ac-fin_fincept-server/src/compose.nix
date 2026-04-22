# compose.nix — docker-compose spec for fincept-server (Type A, own code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    fincept-server = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        FINCEPT_PORT = toString app.port;
        RUST_LOG = "info,tower_http=info";
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "128M"; };
      };
    };
  };
}
