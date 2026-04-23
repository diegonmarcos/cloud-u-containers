# compose.nix — pure attrset describing docker-compose.yml for stalwart.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  app    = buildJson.containers.app;
  sorter = buildJson.containers.sorter;

  # Engine wraps the upstream stalwart image into
  # ghcr.io/diegonmarcos/<name>-binaries:latest; at runtime we pull that image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  appPort       = toString app.port;

  # Port mappings driven by extra_ports[].bind in build.json.
  # Format: "BIND_IP:HOST_PORT:CONTAINER_PORT" — controls which host interface
  # each port is published on. WG-only ports use 10.0.0.3; loopback-only use
  # 127.0.0.1; public ports use 0.0.0.0. Container-internal listener stays [::].
  portMappings = map (ep:
    "${ep.bind or "0.0.0.0"}:${toString ep.port}:${toString ep.port}"
  ) (app.extra_ports or []);
in
{
  services = {
    stalwart = {
      image          = binariesImage;
      container_name = app.container_name;
      entrypoint     = [ "stalwart" "--config" "/opt/stalwart-mail/etc/config.toml" ];
      ports          = portMappings;
      environment = {
        TZ = buildJson.timezone;
      };
      volumes = [
        "stalwart_data:/opt/stalwart-mail/data"
        # TLS provisioned out-of-band by Caddy (shared with maddy's /opt/containers/maddy/tls)
        "/opt/containers/maddy/tls:/opt/stalwart-mail/tls:ro"
        "./configs/config.toml:/opt/stalwart-mail/etc/config.toml:ro"
      ];
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
    stalwart-sorter = {
      image          = sorter.image;
      container_name = sorter.container_name;
      entrypoint     = [ "python3" "/app/jmap-sorter.py" ];
      env_file       = [ ".secrets" ];
      environment = {
        JMAP_URL       = "https://localhost:${appPort}";
        RULES_PATH     = "/data/mail-rules.json";
        STARTUP_DELAY  = "20";
      };
      volumes = [
        "./assets/jmap-sorter.py:/app/jmap-sorter.py:ro"
        "./assets/mail-rules.json:/data/mail-rules.json:ro"
      ];
      deploy.resources = {
        limits       = { memory = sorter.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = sorter.resources.mem_reservation; };
      };
    };
  };
  volumes = {
    stalwart_data = {};
  };
}
