# compose.nix — docker-compose spec for ntfy + syslog-bridge + github-rss + rss-gateway.
# engine.nix serialises this via lib.generators.toYAML and merges
# compose-defaults.json into every service. Paths are relative to dist/
# (docker-compose project-directory at deploy time).
{ buildJson, cNtfy, cSyslog, cGithubRss, cRssGateway, containerNtfy }:

let
  svc          = containerNtfy.services;
  appC         = buildJson.containers.app;
  syslogC      = buildJson.containers."syslog-bridge";
  githubRssC   = buildJson.containers."github-rss";
  rssGatewayC  = buildJson.containers."rss-gateway";

  # Main container uses the wrapped-upstream image emitted by the engine
  # into code/<arch>/Dockerfile. Side-car Python containers pull their
  # upstream image directly (no bake needed; scripts are bind-mounted).
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  pythonImage   = cSyslog.image; # python:3.11-slim (same for both side-cars)

  tz = buildJson.timezone;
in
{
  services = {
    ntfy = {
      image = binariesImage;
      container_name = appC.container_name;
      entrypoint = [ "sh" "/init.sh" ];
      env_file = [ ".secrets" ];
      environment = {
        TZ = tz;
      };
      volumes = [
        "./configs/server.yml:/etc/ntfy/server.yml:ro"
        "./configs/init.sh:/init.sh:ro"
        "ntfy_cache:/var/cache/ntfy"
      ];
      # Tier-3 wg-only bind: data-driven IP from containerNtfy.services.<self>.ip
      # (cloud-data-config-derive emits svc.<name>.ip per VM WG address).
      ports = [ "${svc.ntfy.ip}:${toString buildJson.ports.app}:${toString buildJson.ports.app}" ];
      deploy.resources = {
        limits       = { memory = appC.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = appC.resources.reservations.memory; };
      };
    };

    syslog-bridge = {
      image = pythonImage;
      container_name = syslogC.container_name;
      command = "python -u /app/syslog-to-ntfy.py";
      environment = {
        TZ = tz;
        PYTHONUNBUFFERED = "1";
      };
      volumes = [
        "./assets/syslog-to-ntfy.py:/app/syslog-to-ntfy.py:ro"
        "ntfy_cache:/var/cache/ntfy"
        "/var/log:/var/log:ro"
      ];
      depends_on.ntfy = { condition = "service_started"; };
      deploy.resources = {
        limits       = { memory = syslogC.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = syslogC.resources.reservations.memory; };
      };
    };

    github-rss = {
      image = pythonImage;
      container_name = githubRssC.container_name;
      command = "python -u /app/github-rss-to-ntfy.py";
      environment = {
        TZ = tz;
        PYTHONUNBUFFERED = "1";
      };
      volumes = [
        "./assets/github-rss-to-ntfy.py:/app/github-rss-to-ntfy.py:ro"
        "ntfy_cache:/var/cache/ntfy"
      ];
      depends_on.ntfy = { condition = "service_started"; };
      deploy.resources = {
        limits       = { memory = githubRssC.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = githubRssC.resources.reservations.memory; };
      };
    };

    rss-gateway = {
      image = pythonImage;
      container_name = rssGatewayC.container_name;
      command = "python -u /app/rss-gateway.py";
      environment = {
        TZ = tz;
        PYTHONUNBUFFERED = "1";
      };
      volumes = [
        "./assets/rss-gateway.py:/app/rss-gateway.py:ro"
        "./assets/profiles-config.json:/etc/ntfy/profiles-config.json:ro"
      ];
      # Bind to WG IP so Caddy (gcp-proxy) can reach the gateway over the mesh;
      # same pattern as the main ntfy app container.
      ports = [ "${svc.ntfy.ip}:${toString buildJson.ports.rss_gateway}:${toString buildJson.ports.rss_gateway}" ];
      depends_on.ntfy = { condition = "service_started"; };
      deploy.resources = {
        limits       = { memory = rssGatewayC.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = rssGatewayC.resources.reservations.memory; };
      };
    };
  };

  volumes = {
    ntfy_cache = {};
  };
}
