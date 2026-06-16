# compose.nix — pure attrset describing docker-compose.yml for Element Web.
{ buildJson, container, base_domain }:

let
  svc  = container.services;
  self = svc."matrix-element";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    matrix-element = {
      image = binariesImage;
      container_name = buildJson.containers.app.container_name;
      # element-web's nginx listens on :80 inside; publish on the WG IP so
      # Caddy (edge) can reach it as matrix-element.app:8082 over WireGuard.
      ports = [ "${self.ip}:${toString buildJson.ports.app}:80" ];
      volumes = [ "./configs/config.json:/app/config.json:ro" ];
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "0.5"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
}
