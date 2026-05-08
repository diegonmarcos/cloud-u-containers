# compose.nix — pure attrset describing docker-compose.yml for wireguard-mesh.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain ? null }:

let
  app = buildJson.containers.app;

  # Built locally on the deploy host (REMOTE_BUILD path) — small static bundle,
  # no need for cross-arch GHCR push for this service.
  imageRef = "wireguard-mesh:local";
in
{
  services = {
    wireguard-mesh = {
      build = {
        context    = ".";
        dockerfile = "src/Dockerfile";
      };
      image = imageRef;
      container_name = app.container_name;
      read_only = true;
      tmpfs = app.tmpfs or [ "/var/cache/nginx" "/var/run" ];
      ports = [
        "${toString buildJson.ports.app}:${toString app.port}"
      ];
      environment = {
        TZ = buildJson.timezone or "Europe/Madrid";
      };
      restart = "unless-stopped";
      healthcheck = {
        test     = app.healthcheck.test;
        interval = app.healthcheck.interval;
        timeout  = app.healthcheck.timeout;
        retries  = app.healthcheck.retries;
      };
      deploy = {
        resources = {
          limits = {
            memory = app.resources.mem_limit;
          };
        };
      };
      logging = {
        driver = "json-file";
        options = {
          max-size = "1m";
          max-file = "3";
        };
      };
    };
  };
}
