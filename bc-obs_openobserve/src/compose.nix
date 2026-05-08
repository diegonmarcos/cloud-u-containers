{ buildJson, container }:

let
  svc           = container.services;
  app           = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  appPort = toString buildJson.ports.app;
  bindIp  = svc.openobserve.ip;
in
{
  services = {
    openobserve = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      environment = {
        ZO_HTTP_PORT  = appPort;
        ZO_HTTP_ADDR  = bindIp;
        ZO_GRPC_PORT  = "5081";
        ZO_GRPC_ADDR  = bindIp;
        ZO_DATA_DIR   = "/data";
        ZO_LOCAL_MODE = "true";
        ZO_TELEMETRY  = "false";
        ZO_BASE_URI   = "";
        # Memory diet — write-only ingest endpoint (fluent-bit POSTs from
        # 4 VMs, ~10 KB/s). No queries, no dashboards, no alerts. Default
        # config wastes ~300 MiB on unused query infrastructure:
        #   - 128 MiB MEM cache pool (sized even with ENABLED=false)
        #   - 192 MiB DataFusion query pool (auto-sized from cgroup)
        #   - 2× actix workers + grpc workers + alert scheduler stacks
        # Banner reports these as "Caches info" at startup. Each knob below
        # is set to its minimum viable value for ingest-only use.
        # Verified before #1: 382 MiB → after #1: 212 MiB. Target ≤80 MiB.
        ZO_MEMORY_CACHE_ENABLED          = "false";
        ZO_MEMORY_CACHE_MAX_SIZE         = "8";       # MiB — was 128
        ZO_DISK_CACHE_ENABLED            = "false";
        ZO_MEM_TABLE_BUCKET_NUM          = "1";
        ZO_MEM_TABLE_MAX_SIZE            = "8";       # MiB ingest buffer
        ZO_FILE_PUSH_INTERVAL            = "10";      # seconds
        ZO_DATAFUSION_MIN_PARTITION_NUM  = "1";       # was auto = NUM_CPU
        # DataFusion pool size = ratio × available_mem. Default 0.5 → 252 MiB
        # on a 512 MiB cgroup. We never run queries (write-only ingest), so
        # this pool is wasted. Drop to 5% of mem (≈26 MiB) — DataFusion is
        # still used internally during parquet writes for sort/aggregate
        # within a single batch, hence not zero.
        ZO_MEM_DATAFUSION_RATIO          = "0.05";
        ZO_HTTP_WORKER_NUM               = "1";       # actix HTTP workers
        ZO_GRPC_WORKER_NUM               = "1";       # grpc unused locally
        ZO_QUERY_THREAD_NUM              = "1";       # no queries
        ZO_FEATURE_QUERY_QUEUE_ENABLED   = "false";
        ZO_USAGE_REPORTING_ENABLED       = "false";
        ZO_LIMIT_CONCURRENT_REQUESTS     = "16";      # cap simultaneous ingest
      };
      volumes = [
        "openobserve_data:/data"
      ];
      # OpenObserve image is scratch-based (only /openobserve, no shell, no
      # wget/curl). Docker cannot exec any probe inside, so the in-container
      # healthcheck is disabled. Liveness comes from the process itself
      # (Docker exits the container if /openobserve crashes); external
      # /healthz monitoring is done by the cloud-infra MCP tools that hit
      # https://grafana.diegonmarcos.com/healthz from outside.
      healthcheck = {
        disable = true;
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "128M"; };
      };
    };
  };

  volumes = {
    openobserve_data = {};
  };
}
