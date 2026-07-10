# compose.nix — docker-compose spec for scrappers-api (Type A own-code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."scrappers-api".ip or "10.0.0.6";  # oci-apps WG IP
  port = toString buildJson.ports.app;
in
{
  services = {
    scrappers-api = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      # NOTE: when the burner IG account exists, add `env_file = [ ".secrets" ];` here plus a
      # sops src/secrets.yaml carrying IG_BURNER_USER / IG_BURNER_PASS. Until then the IG scraper
      # runs anonymously (public profiles only) and needs no secrets.
      environment = {
        PYTHONUNBUFFERED = "1";
        DATA_DIR = "/app/data";
        TZ = buildJson.timezone;
        BASE_PATH = "/scrappers";
        PORT = port;
        # Confine the listener to the WG mesh on host networking.
        HTTP_HOST = vmIp;
      };
      volumes = [
        "scrappers_data:/app/data"        # flat-JSON scrape output (restic-backed)
        "scrappers_session:/app/session"  # instaloader burner session cache
      ];
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -fsS http://${vmIp}:${port}/health >/dev/null 2>&1 || exit 1"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "20s";
      };
    };
  };
  volumes = {
    scrappers_data = {};
    scrappers_session = {};
  };
}
