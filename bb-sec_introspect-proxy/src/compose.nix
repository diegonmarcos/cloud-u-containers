# compose.nix — pure attrset describing docker-compose.yml for introspect-proxy.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Single service: introspect-proxy — OIDC token introspection sidecar for Caddy
#   - Own code (Type A) packaged by ship engine via native_build.type=image-wrapper
#   - host networking so Caddy at 127.0.0.1 can forward_auth to :4182
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    introspect-proxy = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      # Explicit command override: ensures gunicorn binds to 0.0.0.0 even
      # if the cached/published GHCR image's CMD still has the older
      # 127.0.0.1 hardcode (current binary build does 0.0.0.0). Caddy
      # forward_auth calls `<gcp-proxy WG IP>:4182` per
      # cloud-data-config-derive.ts (auth_upstreams = `${vm.wg_ip}:${port}`),
      # so the listener MUST be reachable from a non-loopback interface.
      command = [
        "gunicorn"
        "--bind" "0.0.0.0:${toString buildJson.ports.app}"
        "--workers" "1" "--threads" "1" "--timeout" "120"
        "main:app"
      ];
      environment = {
        JWKS_URL       = "https://auth.diegonmarcos.com/jwks.json";
        ISSUER         = "https://auth.diegonmarcos.com";
        REQUIRED_SCOPE = "authelia.bearer.authz";
        PORT           = toString buildJson.ports.app;
      };
      healthcheck = {
        test = [
          "CMD" "python3" "-c"
          "import urllib.request; urllib.request.urlopen('http://localhost:${toString buildJson.ports.app}/health')"
        ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
}
