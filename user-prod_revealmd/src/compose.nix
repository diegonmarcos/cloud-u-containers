# compose.nix — docker-compose spec for revealmd (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  port = toString buildJson.ports.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    revealmd = {
      image = binariesImage;
      container_name = app.container_name;
      # Tier-3 wg-only bind: data-driven IP from container.services.<self>.ip
      # (cloud-data-config-derive emits svc.<name>.ip per VM WG address).
      ports = [ "${svc.revealmd.ip}:${port}:${port}" ];
      volumes = [ "slides_data:/slides" ];
      command = "/slides --watch --port ${port}";
      healthcheck = {
        test = [ "CMD" "wget" "-q" "--spider" "http://localhost:${port}" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
      };
      deploy.resources = {
        limits       = { memory = "256M"; cpus = "0.5"; };
        reservations = { memory = "64M"; };
      };
    };
  };
  volumes = {
    slides_data = {};
  };
}
