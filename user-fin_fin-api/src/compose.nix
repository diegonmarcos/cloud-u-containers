# compose.nix — docker-compose spec for fin-api (Type A, own code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  # WG IP from cloud-data — bound by source (defensive default 127.0.0.1
  # in main.rs; we override via FIN_API_HOST). Host network mode means the
  # service stays on the WG mesh only.
  vmIp = svc."fin-api".ip or "10.0.0.6";
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
        FIN_API_HOST = vmIp;
        RUST_LOG = "info,tower_http=info";
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "128M"; };
      };
    };
  };
}
