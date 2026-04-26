# compose.nix — docker-compose spec for fin-api (Type A, own code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    fin-api = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        FIN_API_PORT = toString app.port;
        RUST_LOG = "info,tower_http=info";
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "128M"; };
      };
    };
  };
}
