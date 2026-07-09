# compose.nix — pure attrset describing docker-compose.yml for mautrix-whatsapp.
{ buildJson, container, base_domain }:

let
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    mautrix-whatsapp = {
      image = binariesImage;
      container_name = buildJson.containers.app.container_name;
      # host network: reaches the homeserver on the WG IP and listens for the
      # homeserver's appservice callbacks on the same WG IP:port.
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        TZ = buildJson.timezone;
      };
      volumes = [ "./data:/data" ];
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
}
