# compose.nix — docker-compose spec for send (timvisee/send).
# Two services: send_app (the web server) + send_redis (ephemeral store).
# Redis is container-internal only — no port exposed on host.
# engine.nix serialises this attrset via lib.generators.toYAML.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  cfg = buildJson.send_config;
in
{
  services = {
    send = {
      image          = "registry.gitlab.com/timvisee/send:latest";
      container_name = app.container_name;
      depends_on     = [ "redis" ];
      ports = [
        "${svc.send.ip}:${toString buildJson.ports.app}:1234"
      ];
      environment = {
        NODE_ENV          = "production";
        BASE_URL          = "https://${buildJson.domain}";
        PORT              = "1234";
        REDIS_HOST        = "redis";
        REDIS_PORT        = "6379";
        MAX_FILE_SIZE     = toString cfg.max_file_size_bytes;
        MAX_DOWNLOADS     = toString cfg.max_downloads;
        EXPIRE_TIMES_SECONDS   = toString cfg.default_expire_seconds;
        DEFAULT_EXPIRE_SECONDS = toString cfg.default_expire_seconds;
        MAX_EXPIRE_SECONDS     = toString cfg.max_expire_seconds;
        UPLOAD_STORAGE    = "filesystem";
        FILE_DIR          = "/uploads";
      };
      volumes = [
        "send_uploads:/uploads"
      ];
      healthcheck = {
        # 127.0.0.1 not localhost: the send node server binds IPv4 0.0.0.0:1234
        # only, but `localhost` resolves to IPv6 ::1 first in the busybox image →
        # wget gets "connection refused" and the container is falsely marked
        # unhealthy while send.diegonmarcos.com serves fine (verified 2026-07-10).
        test     = [ "CMD" "wget" "-q" "--spider" "http://127.0.0.1:1234/__lbheartbeat__" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
    };

    redis = {
      image          = "redis:7-alpine";
      container_name = "send_redis";
      command        = "redis-server --save 60 1 --loglevel warning";
      volumes = [
        "send_redis_data:/data"
      ];
    };
  };

  volumes = {
    send_uploads   = {};
    send_redis_data = {};
  };
}
