# compose.nix — docker-compose spec for c3-analytics-api (Type A own-code)
# Runs on gcp-proxy, host-network, public via Caddy at /c3a/*.
# Backend URLs resolved at build time from cloud-data (cross-VM via WG).
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # gcp-proxy WG IP for binding + healthcheck
  myIp = svc."c3-analytics-api".ip or "10.0.0.1";
  port = toString buildJson.ports.app;
  basePath = buildJson.proxy.primary.base_path;

  # Resolve each backend slug → URL using cloud-data svc table.
  # service.ip is its WG IP (oci-apps = 10.0.0.6); service.ports.app is
  # the canonical app port from the backend's own build.json.
  mkBackend = _slug: cfg:
    let s = svc.${cfg.service}; in {
      url = "http://${s.ip}:${toString s.ports.app}${cfg.rewrite_path}";
      service = cfg.service;
      methods = cfg.methods;
      auth_header_env = cfg.auth_header_env or null;
    };

  backends = builtins.mapAttrs mkBackend buildJson.backends;
  backendsJson = builtins.toJSON backends;
  sitesJson = builtins.toJSON buildJson.sites;
  limitsJson = builtins.toJSON buildJson.limits;
in
{
  services = {
    c3-analytics-api = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        HOST = myIp;
        PORT = port;
        NODE_ENV = "production";
        BASE_PATH = basePath;
        BACKENDS_JSON = backendsJson;
        SITES_JSON = sitesJson;
        LIMITS_JSON = limitsJson;
      };
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -fsS http://${myIp}:${port}${basePath}/healthz >/dev/null 2>&1 || exit 1"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
      deploy.resources = {
        limits       = { memory = "192M"; cpus = "1.0"; };
        reservations = { memory = "48M"; };
      };
    };
  };
}
