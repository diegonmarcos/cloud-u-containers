# compose.nix — pure attrset describing docker-compose.yml for authelia.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  svc = container.services;
  app = buildJson.containers.app;
  redis = buildJson.containers.redis;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  redisImage    = redis.image;
in
{
  services = {
    authelia = {
      image = binariesImage;
      container_name = app.container_name;
      entrypoint = [ "sh" "/config/init.sh" ];
      env_file = [ ".secrets" ];
      environment = {
        TZ = buildJson.timezone;
        X_AUTHELIA_CONFIG_FILTERS = "template";
      };
      volumes = [
        "authelia_data:/data"
        "./configs:/config:ro"
      ];
      # NOTE: .secrets, .secrets.d/, .secrets.json are auto-mounted by
      # _shared/engine.nix when src/secrets.yaml exists. Authelia's
      # configuration.yml uses {{ secret "/run/secrets/X" }} for all secret
      # references including the multi-line JWKS PEM. No oidc_jwks.pem
      # carve-out, no legacy /config/.secrets.d mount needed.
      ports = [ "${svc.authelia.ip}:${toString buildJson.ports.app}:9091" ];
      networks = [ "auth-net" ];
      depends_on.redis = { condition = "service_started"; };
      cap_add = [ "DAC_OVERRIDE" ];
      deploy.resources = {
        limits       = { memory = "128M"; cpus = "1.0"; };
        reservations = { memory = "32M"; };
      };
    };
    redis = {
      image = redisImage;
      container_name = redis.container_name;
      env_file = [ ".secrets" ];
      command = "sh -c 'redis-server --port ${toString buildJson.ports.redis} --requirepass $$AUTHELIA_REDIS_PASSWORD --appendonly yes --appendfsync everysec --save 900 1 --save 300 10'";
      volumes = [ "authelia_redis_data:/data" ];
      networks = [ "auth-net" ];
      deploy.resources = {
        limits       = { memory = "48M"; cpus = "1.0"; };
        reservations = { memory = "16M"; };
      };
    };
  };
  volumes = {
    authelia_data = {};
    authelia_redis_data = {};
  };
  networks = {
    auth-net = { driver = "bridge"; };
  };
}
