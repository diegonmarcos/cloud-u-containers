# compose.nix — Cloud Notes web: the static app (nginx, port 80 inside) published on the WG IP so the
# edge (Caddy) reaches it over WireGuard. No secret, no volume: the edge gate authenticates.
{ buildJson, container, base_domain }:

let
  svc  = container.services;
  self = svc."cloud-notes-web";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    cloud-notes-web = {
      image = binariesImage;
      container_name = buildJson.containers.app.container_name;
      ports = [ "${self.ip}:${toString buildJson.ports.app}:80" ];
      deploy.resources =
           { limits = { cpus = "0.5"; } // (if buildJson.resources ? mem_limit then { memory = buildJson.resources.mem_limit; } else {}); }
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };
}
