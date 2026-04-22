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
      env_file = [ ".secrets" ];
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
