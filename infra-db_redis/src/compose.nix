# compose.nix — pure attrset describing docker-compose.yml for redis.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  port            = toString buildJson.ports.app;
  bindIp          = svc.redis.ip;
  maxmemory       = buildJson.redis.maxmemory;
  maxmemoryPolicy = buildJson.redis.maxmemory_policy;

  # NOTE: "$$REDIS_PASSWORD" is compose-escaped so docker-compose forwards
  # the literal "$REDIS_PASSWORD" into the container (env_file supplies it).
  redisCmd =
    "redis-server --appendonly yes "
    + "--port ${port} "
    + "--bind ${bindIp} 127.0.0.1 "
    + "--maxmemory ${maxmemory} "
    + "--maxmemory-policy ${maxmemoryPolicy} "
    + "--requirepass \"$$REDIS_PASSWORD\"";
in
{
  services = {
    redis = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      command = [ "sh" "-c" redisCmd ];
      volumes = [ "/data/redis:/data" ];
      deploy.resources = {
        limits       = { memory = "48M"; cpus = "1.0"; };
        reservations = { memory = "16M"; };
      };
      healthcheck = {
        test     = [ "CMD" "redis-cli" "-p" port "ping" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
    };
  };
}
