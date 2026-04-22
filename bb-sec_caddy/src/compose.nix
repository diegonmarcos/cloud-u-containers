# compose.nix — docker-compose spec for caddy + introspect-proxy
{ buildJson, container }:

let
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    caddy = {
      image = binariesImage;
      container_name = "caddy";
      network_mode = "host";
      env_file = [ ".secrets" ];
      depends_on = [ "introspect-proxy" ];
      cap_add = [ "NET_BIND_SERVICE" ];
      read_only = false;
      volumes = [
        "./configs/Caddyfile:/etc/caddy/Caddyfile:ro"
        "./configs/error.html:/srv/error.html:ro"
        "./configs/dashboard.html:/srv/dashboard.html:ro"
        "./configs/ntfy-setup.html:/srv/ntfy-setup.html:ro"
        "./configs/mail:/srv/mail:ro"
        "./configs/wkd:/srv/wkd:ro"
        "caddy_logs:/var/log/caddy"
        "caddy_data:/data"
        "caddy_config:/config"
      ];
      deploy.resources = {
        limits       = { memory = "128M"; };
        reservations = { memory = "48M"; };
      };
    };

    introspect-proxy = {
      image = "ghcr.io/diegonmarcos/introspect-proxy-binaries:latest";
      container_name = "introspect-proxy";
      network_mode = "host";
      environment = {
        JWKS_URL = "https://auth.diegonmarcos.com/jwks.json";
        ISSUER = "https://auth.diegonmarcos.com";
        REQUIRED_SCOPE = "authelia.bearer.authz";
        DEBUG = "true";
      };
      deploy.resources = {
        limits       = { memory = "64M"; };
        reservations = { memory = "16M"; };
      };
      healthcheck = {
        test = [ "CMD" "python3" "-c" "import urllib.request; urllib.request.urlopen('http://localhost:4182/health')" ];
        interval = "30s";
        timeout = "5s";
        retries = 3;
        start_period = "10s";
      };
    };
  };

  volumes = {
    caddy_data   = { driver = "local"; };
    caddy_config = { driver = "local"; };
    caddy_logs   = { driver = "local"; };
  };
}
