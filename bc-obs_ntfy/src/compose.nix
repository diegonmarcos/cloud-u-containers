# compose.nix — docker-compose spec for ntfy + syslog-bridge + github-rss.
# engine.nix serialises this via lib.generators.toYAML and merges
# compose-defaults.json into every service. Paths are relative to dist/
# (docker-compose project-directory at deploy time).
{ buildJson, cNtfy, cSyslog, cGithubRss }:

let
  appC       = buildJson.containers.app;
  syslogC    = buildJson.containers."syslog-bridge";
  githubRssC = buildJson.containers."github-rss";

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
      ports = [ "${toString buildJson.ports.app}:${toString buildJson.ports.app}" ];
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
  };

  volumes = {
    ntfy_cache = {};
  };
}
