# compose.nix — unbound-dns64
{ buildJson, container }:

let
  app = buildJson.containers.app;
  image = "ghcr.io/diegonmarcos/unbound-dns64:latest";
in
{
  services = {
    unbound-dns64 = {
      image = image;
      container_name = app.container_name;
      # host networking: binds directly on port 53 (UDP+TCP) of every
      # interface including the public IPv6 — required so external DNS64
      # clients and the OCI /64 can reach it without DNAT.
      network_mode = "host";
      volumes = [
        "./configs/unbound.conf:/etc/unbound/unbound.conf:ro"
      ];
      deploy.resources = {
        limits       = { memory = "64M"; cpus = "0.5"; };
        reservations = { memory = "16M"; };
      };
    };
  };
}
