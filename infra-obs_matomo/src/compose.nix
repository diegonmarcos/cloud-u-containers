# compose.nix — docker-compose spec for matomo-hybrid (Type A own-code).
# Single container bundling receiver (nginx + php-fpm) + Matomo (nginx +
# php-fpm) + MariaDB, supervised by supervisord. engine.nix serialises this
# attrset via lib.generators.toYAML and merges compose-defaults.json.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    matomo-hybrid = {
      image = binariesImage;
      container_name = app.container_name;
      # External port → internal 8080 (receiver-nginx default_server).
      # receiver-nginx handles public tracker endpoints and proxies admin
      # traffic to matomo-nginx on 8081 internally.
      ports = [ "${svc.matomo.ip}:${toString app.port}:8080" ];
      volumes = [
        "matomo_matomo_data:/var/www/html"
        "matomo_matomo_db:/var/lib/mysql"
        "matomo_inbox:/inbox"
      ];
      env_file = [ ".secrets" ];
      environment = {
        MATOMO_DATABASE_HOST     = "localhost";
        MATOMO_DATABASE_USERNAME = "\${MATOMO_DB_USER:-matomo}";
        MATOMO_DATABASE_PASSWORD = "\${MATOMO_DB_PASSWORD:-MatomoDB2025!}";
        MATOMO_DATABASE_DBNAME   = "\${MATOMO_DB_NAME:-matomo}";
        MATOMO_API_TOKEN         = "\${MATOMO_API_TOKEN}";
      };
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
  };
  volumes = {
    matomo_matomo_data = { name = "matomo_matomo_data"; };
    matomo_matomo_db   = { name = "matomo_matomo_db"; };
    matomo_inbox       = { name = "matomo_inbox"; };
  };
}
