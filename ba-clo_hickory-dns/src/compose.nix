# compose.nix — hickory-dns
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    hickory-dns = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        RUST_LOG = "hickory_dns=info,hickory_server=info";
      };
      volumes = [
        "./configs/named.toml:/etc/named.toml:ro"
        "./configs/zones:/etc/zones:ro"
      ];
      deploy.resources = {
        limits       = { memory = "48M"; cpus = "0.5"; };
        reservations = { memory = "16M"; };
      };
    };
  };
}
