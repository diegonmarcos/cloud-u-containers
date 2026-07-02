# compose.nix — docker-compose spec for crawlee-cloud (v2).
#
# Multi-container self-hosted Apify-compatible scraping platform:
#   api        — built from patched upstream (dist/assets/repo/docker/Dockerfile.api)
#   runner     — built from patched upstream (Dockerfile.runner); exposes docker sock
#   dashboard  — built from patched upstream (Dockerfile.dashboard)
#   scheduler  — reuses api image; different command
#   db         — postgres:16-alpine (wrapped via build context)
#   redis      — redis:7-alpine
#   minio      — minio/minio (object storage)
#   minio_init — minio/mc one-shot bucket creation
#
# Build contexts point to ./assets/repo (patched upstream source emitted
# by flake.nix as an asset). engine.nix merges compose-defaults.json.
{ buildJson, container }:

let
  c             = buildJson.containers;
  app           = c.app;
  runnerC       = c.runner;
  dashboardC    = c.dashboard;
  schedulerC    = c.scheduler;
  db            = c.db;
  redis         = c.redis;
  minio         = c.minio;

  # Image names come from build.json containers.<x>.image — the declared
  # `:local` tags. These are VM-built images (compose `build:` blocks +
  # deploy.compose_flags="--build" rebuild them natively on the arm64 VM
  # from the shipped dist/assets/repo). NEVER invent GHCR-style names here:
  # a registry-named tag lets a stale amd64 pull shadow the local build →
  # "Exec format error" under arm64 tini.
  apiImage       = app.image;
  runnerImage    = runnerC.image;
  dashboardImage = dashboardC.image;
  schedulerImage = schedulerC.image;

  apiPort          = toString buildJson.ports.app;
  dashboardPort    = toString buildJson.ports.dashboard;
  minioPort        = toString buildJson.ports.minio;
  minioConsolePort = toString buildJson.ports.minio_console;
  dbPort           = toString buildJson.ports.db;
  redisPort        = toString buildJson.ports.redis;

  runtime = buildJson.runtime;

  # Common command wrapper to compose DATABASE_URL from secrets env
  # (POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB come from .secrets).
  # In production (NODE_ENV=production) the api's config.js env() helper
  # IGNORES its dev-defaults and THROWS for any unset var. So every
  # required var must be explicitly provided. Secrets come via the command
  # wrapper (reusing .secrets env_file values); plain config comes via the
  # environment block below. API_SECRET reuses the existing JWT_SECRET
  # secret (same trust domain — the api's signing key) rather than minting
  # a second credential.
  apiCmd = ''
    sh -c '
      export DATABASE_URL="postgresql://$$POSTGRES_USER:$$POSTGRES_PASSWORD@$$DB_HOST:$$DB_PORT/$$POSTGRES_DB?sslmode=disable"
      export S3_ACCESS_KEY="$$MINIO_USER"
      export S3_SECRET_KEY="$$MINIO_PASSWORD"
      export API_SECRET="$$JWT_SECRET"
      node packages/api/dist/db/migrate.js && exec node packages/api/dist/index.js
    '
  '';
  runnerCmd = ''
    sh -c '
      export DATABASE_URL="postgresql://$$POSTGRES_USER:$$POSTGRES_PASSWORD@$$DB_HOST:$$DB_PORT/$$POSTGRES_DB?sslmode=disable"
      export API_TOKEN="$$RUNNER_TOKEN"
      exec node dist/index.js
    '
  '';
  schedulerCmd = ''
    sh -c '
      export DATABASE_URL="postgresql://$$POSTGRES_USER:$$POSTGRES_PASSWORD@$$DB_HOST:$$DB_PORT/$$POSTGRES_DB?sslmode=disable"
      exec sleep infinity
    '
  '';

  # Build context paths relative to compose/ project-directory (CWD of
  # docker compose at deploy). ship engine runs `docker compose -f
  # compose/docker-compose.yml --project-directory .` so relative paths
  # resolve from dist/.
  repoContext = "./assets/repo";
in
{
  services = {
    api = {
      image = apiImage;
      build = {
        context    = repoContext;
        dockerfile = "docker/Dockerfile.api";
      };
      container_name = app.container_name;
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      environment = {
        NODE_ENV            = runtime.node_env;
        PORT                = apiPort;
        # Bind all interfaces (incl. the wg0 IP 10.0.0.6) — the api defaults to
        # 127.0.0.1, so a full WG peer can't reach it (report probes 10.0.0.6:3000;
        # 2026-06-23). HOST is the de-facto Node listen-host env; harmless if the
        # app ignores it. (Public side is firewall-closed on oci-apps.)
        HOST                = "0.0.0.0";
        REDIS_URL           = "redis://localhost:${redisPort}";
        S3_ENDPOINT         = "http://localhost:${minioPort}";
        S3_BUCKET           = runtime.s3_bucket;
        # MinIO ignores the region but the api config.js hard-requires it
        # (throws 'Missing required environment variable: S3_REGION').
        S3_REGION           = runtime.s3_region;
        S3_FORCE_PATH_STYLE = if runtime.s3_force_path_style then "true" else "false";
        # Required in production (no dev-default fallback). Data-driven.
        CORS_ORIGINS        = runtime.cors_origins;
        RATE_LIMIT_MAX      = toString runtime.rate_limit_max;
        LOG_LEVEL           = runtime.log_level;
        DB_HOST             = "localhost";
        DB_PORT             = dbPort;
      };
      command = apiCmd;
      depends_on = {
        "${db.container_name}"    = { condition = "service_healthy"; };
        "${redis.container_name}" = { condition = "service_healthy"; };
        "${minio.container_name}" = { condition = "service_healthy"; };
      };
      healthcheck = {
        test        = [ "CMD-SHELL" "wget -qO /dev/null http://127.0.0.1:${apiPort}/health || exit 1" ];
        interval    = "15s";
        timeout     = "5s";
        retries     = 3;
        start_period = "20s";
      };
    };

    runner = {
      image = runnerImage;
      build = {
        context    = repoContext;
        dockerfile = "docker/Dockerfile.runner";
      };
      container_name = runnerC.container_name;
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      environment = {
        NODE_ENV                = runtime.node_env;
        API_BASE_URL            = "http://localhost:${apiPort}";
        REDIS_URL               = "redis://localhost:${redisPort}";
        DOCKER_SOCKET           = "/var/run/docker.sock";
        DOCKER_NETWORK          = "host";
        MAX_CONCURRENT_RUNS     = toString runtime.max_concurrent_runs;
        ACTOR_MAX_MEMORY_MB     = toString runtime.actor_max_memory_mb;
        ACTOR_DEFAULT_MEMORY_MB = toString runtime.actor_default_memory_mb;
        ACTOR_TIMEOUT_SECS      = toString runtime.actor_timeout_secs;
        DB_HOST                 = "localhost";
        DB_PORT                 = dbPort;
      };
      command = runnerCmd;
      volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ];
      depends_on.api = { condition = "service_healthy"; };
    };

    dashboard = {
      image = dashboardImage;
      build = {
        context    = repoContext;
        dockerfile = "docker/Dockerfile.dashboard";
      };
      container_name = dashboardC.container_name;
      network_mode   = "host";
      environment = {
        NODE_ENV            = runtime.node_env;
        PORT                = dashboardPort;
        HOSTNAME            = runtime.dashboard_hostname;
        NEXT_PUBLIC_API_URL = "http://localhost:${apiPort}";
      };
      depends_on.api = { condition = "service_healthy"; };
      healthcheck = {
        # Probe the SAME host Next.js binds (HOSTNAME=dashboard_hostname,
        # e.g. 10.0.0.6 under network_mode host) — a 127.0.0.1 probe is
        # refused forever and marks a working dashboard unhealthy.
        test         = [ "CMD-SHELL" "wget -qO /dev/null http://${runtime.dashboard_hostname}:${dashboardPort}/ || exit 1" ];
        interval     = "15s";
        timeout      = "5s";
        retries      = 3;
        start_period = "30s";
      };
    };

    scheduler = {
      image = schedulerImage;
      build = {
        context    = repoContext;
        dockerfile = "docker/Dockerfile.api";
      };
      container_name = schedulerC.container_name;
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      environment = {
        NODE_ENV  = runtime.node_env;
        REDIS_URL = "redis://localhost:${redisPort}";
        DB_HOST   = "localhost";
        DB_PORT   = dbPort;
      };
      command = schedulerCmd;
    };

    "${db.container_name}" = {
      image = db.image;
      container_name = db.container_name;
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      environment.PGPORT = dbPort;
      volumes = [ "crawlee_postgres:/var/lib/postgresql/data" ];
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U $$POSTGRES_USER" ];
        interval = "5s";
        timeout  = "5s";
        retries  = 5;
      };
    };

    "${redis.container_name}" = {
      image = redis.image;
      container_name = redis.container_name;
      network_mode   = "host";
      command = "redis-server --appendonly yes --port ${redisPort}";
      volumes = [ "crawlee_redis:/data" ];
      healthcheck = {
        test     = [ "CMD" "redis-cli" "-p" redisPort "ping" ];
        interval = "5s";
        timeout  = "5s";
        retries  = 5;
      };
    };

    "${minio.container_name}" = {
      image = minio.image;
      container_name = minio.container_name;
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      entrypoint     = [ "sh" "-c" ];
      command = [
        ''export MINIO_ROOT_USER="$$MINIO_USER" && export MINIO_ROOT_PASSWORD="$$MINIO_PASSWORD" && exec minio server /data --address ":${minioPort}" --console-address ":${minioConsolePort}"''
      ];
      volumes = [ "crawlee_minio:/data" ];
      healthcheck = {
        test     = [ "CMD" "curl" "-f" "http://localhost:${minioPort}/minio/health/live" ];
        interval = "5s";
        timeout  = "5s";
        retries  = 5;
      };
    };

    minio_init = {
      image          = "minio/mc:latest";
      container_name = "${minio.container_name}_init";
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      depends_on."${minio.container_name}" = { condition = "service_healthy"; };
      entrypoint = [
        "/bin/sh" "-c"
        "mc alias set myminio http://localhost:${minioPort} $$MINIO_USER $$MINIO_PASSWORD; mc mb myminio/${runtime.s3_bucket} --ignore-existing; exit 0;"
      ];
    };
  };

  volumes = {
    crawlee_postgres = { name = "crawlee_postgres"; };
    crawlee_redis    = { name = "crawlee_redis"; };
    crawlee_minio    = { name = "crawlee_minio"; };
  };
}
