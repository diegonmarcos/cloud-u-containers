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
      # Bind to deploy host's WireGuard IP (data-driven from build.json bind_host).
      # Caddy forward_auth on gcp-proxy reaches us via WG (auth_upstreams =
      # `${vm.wg_ip}:${port}` per cloud-data-config-derive.ts). 0.0.0.0 is
      # forbidden by wg0-only policy; 127.0.0.1 unreachable from Caddy.
      command = [
        "gunicorn"
        "--bind" "${buildJson.bind_host}:${toString buildJson.ports.app}"
        "--workers" "1" "--threads" "1" "--timeout" "120"
        "main:app"
      ];
      environment = {
        # Fetch keys straight from Authelia on the mesh, NOT via
        # https://auth.diegonmarcos.com/jwks.json. That public hostname is a
        # circular dependency: the auth.diegonmarcos.com route is itself gated by
        # forward_auth against THIS proxy, so a cold JWKS fetch cannot complete
        # and every bearer validation fails "Auth key server unavailable" (502).
        # This is also the URL Authelia's own discovery document advertises as
        # jwks_uri. ISSUER stays on the public name — it is compared against the
        # token's `iss` claim, never dialled.
        JWKS_URL       = "http://10.0.0.1:9091/jwks.json";
        ISSUER         = "https://auth.diegonmarcos.com";
        REQUIRED_SCOPE = "authelia.bearer.authz";
        PORT           = toString buildJson.ports.app;
      };
      healthcheck = {
        # Hit the actual bind address (host network + wg0-only bind = no localhost
        # listener). bind_host is data-driven from build.json (10.0.0.1 on gcp-proxy).
        test = [
          "CMD" "python3" "-c"
          "import urllib.request; urllib.request.urlopen('http://${buildJson.bind_host}:${toString buildJson.ports.app}/health')"
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
