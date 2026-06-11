# compose.nix — pure attrset describing docker-compose.yml for wireguard-mesh.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain ? null }:

let
  svc = container.services;
  app = buildJson.containers.app;

  # Published binaries image produced by the ship engine from
  # dist/code/<arch>/Dockerfile (flake nativeBuild block) on the
  # arch-matching runner (arm64 → oci-apps cloud-builder). The VM only
  # pulls. The previous `build: context "." / src/Dockerfile` referenced
  # paths that are never rsync'd to the VM (only dist/ ships), so compose
  # could not build and the service never deployed.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    wireguard-mesh = {
      image = binariesImage;
      container_name = app.container_name;
      read_only = true;
      tmpfs = app.tmpfs or [ "/var/cache/nginx" "/var/run" ];
      # Tier-3 wg-only bind: data-driven IP from container.services.<self>.ip
      # (cloud-data-config-derive emits svc.<name>.ip per VM WG address).
      ports = [
        "${svc.wireguard-mesh.ip}:${toString buildJson.ports.app}:${toString app.port}"
      ];
      environment = {
        TZ = buildJson.timezone or "Europe/Madrid";
      };
      # No restart policy — fleet rule: containers are manual-only, recovery
      # is `build.sh ship`. compose-defaults.json sets restart: "no".
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
