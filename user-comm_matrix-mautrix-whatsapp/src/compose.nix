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
        # mem_limit/mem_reservation are optional in build.json (only
        # mem_reservation is declared fleet-wide today). Reading them
        # unconditionally fails eval with "attribute ... missing".
      deploy.resources =
           { limits = { cpus = "1.0"; } // (if buildJson.resources ? mem_limit then { memory = buildJson.resources.mem_limit; } else {}); }
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };
}
