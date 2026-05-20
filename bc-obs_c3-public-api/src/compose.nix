# compose.nix — docker-compose spec for c3-public-api (Type A own-code)
# Runs on oci-analytics, host-network, public via Caddy at /c3-public-api/*.
# Reverse-proxies /analytics/* to matomo/umami/openobserve (resolved at build time
# from cloud-data, cross-VM via wg0). Bridges /mail/http-to-smtp (Bearer) to maddy
# on oci-mail (and shadow-delivers to stalwart) — same JSON-in/SMTP-out contract
# as the legacy aa-sui_tools-http-to-smtp-proxy-api Rust binary, so the CF Worker
# is unchanged.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # oci-analytics WG IP for binding + healthcheck.
  # svc."c3-public-api" appears once the derive engine has run; fall back to
  # services.<deploy.host>.ip lookup via cloud-data vms table. We hard-default
  # to the published oci-analytics wg0 IP only as a safety net so the flake
  # evaluates even before 2_configs has emitted this service's entry.
  myIp = svc."c3-public-api".ip or "10.0.0.4";
  port = toString buildJson.ports.app;
  basePath = buildJson.proxy.primary.base_path;

  # Resolve analytics backend slugs -> URLs using cloud-data svc table.
  mkBackend = _slug: cfg:
    let s = svc.${cfg.service}; in {
      url = "http://${s.ip}:${toString s.ports.app}${cfg.rewrite_path}";
      service = cfg.service;
      methods = cfg.methods;
      auth_header_env = cfg.auth_header_env or null;
    };
  backends = builtins.mapAttrs mkBackend buildJson.backends;
  backendsJson = builtins.toJSON backends;
  limitsJson = builtins.toJSON buildJson.limits;

  # Mail targets — primary (maddy) + shadow (stalwart). Resolved from
  # build.json#mail.primary/shadow which name a service + a port slug.
  mailPrimaryService = buildJson.mail.primary.service;
  mailPrimaryVia = buildJson.mail.primary.via;
  mailShadowService = buildJson.mail.shadow.service;
  mailShadowVia = buildJson.mail.shadow.via;

  primarySvc = svc.${mailPrimaryService};
  shadowSvc = svc.${mailShadowService};

  # Resolve port slug -> port number against extra_ports (services own this
  # map keyed by port number with a `service` slug field).
  portForVia = svcEntry: via:
    let
      ports = svcEntry.extra_ports or {};
      matches = builtins.filter (k: (ports.${k}.service or "") == via) (builtins.attrNames ports);
    in if matches == [] then null else builtins.elemAt matches 0;

  primaryPort = portForVia primarySvc mailPrimaryVia;
  shadowPort = portForVia shadowSvc mailShadowVia;
in
{
  services = {
    c3-public-api = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        HOST = myIp;
        PORT = port;
        NODE_ENV = "production";
        BASE_PATH = basePath;
        # Analytics passthrough config (same shape as c3-analytics-api).
        BACKENDS_JSON = backendsJson;
        LIMITS_JSON = limitsJson;
        # Mail bridge config (replicates http-to-smtp-proxy-api contract).
        SMTP_HOST = primarySvc.ip;
        SMTP_PORT = primaryPort;
        SMTP_SHADOW_HOST = shadowSvc.ip;
        SMTP_SHADOW_PORT = shadowPort;
        SMTP_HELO_DOMAIN = buildJson.mail.helo_domain;
      };
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -fsS http://${myIp}:${port}/health >/dev/null 2>&1 || exit 1"
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
