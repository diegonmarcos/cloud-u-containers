# compose.nix — pure attrset describing docker-compose.yml for snappymail.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  app = buildJson.containers.app;

  # Engine wraps the upstream snappymail image into
  # ghcr.io/diegonmarcos/<name>-binaries:latest; at runtime we pull that image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  port = toString buildJson.ports.app;
in
{
  services = {
    snappymail = {
      image = binariesImage;
      container_name = app.container_name;
      # host network: shares lo with co-located maddy (also host-mode) so
      # domain config can use imap_host=<mail.domain>. VM INPUT policy is DROP
      # except 10.0.0.0/24+lo, so :8888 stays reachable only via WG.
      network_mode = "host";
      volumes = [
        "snappymail_data:/var/lib/snappymail"
        "./configs/application.ini:/opt/snappymail-config/application.ini:ro"
        "./configs/domain.ini:/var/lib/snappymail/_data_/_default_/domains/${base_domain}.ini:ro"
      ];
      entrypoint = [
        "/bin/sh" "-c"
        "cp -f /opt/snappymail-config/application.ini /var/lib/snappymail/_data_/_default_/configs/application.ini 2>/dev/null || true; exec /entrypoint.sh"
      ];
      healthcheck = {
        test = [ "CMD" "curl" "-sf" "http://localhost:${port}/" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "10s";
      };
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
  volumes = {
    snappymail_data = {};
  };
}
