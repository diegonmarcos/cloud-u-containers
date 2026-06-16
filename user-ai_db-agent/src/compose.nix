# compose.nix — pure attrset describing docker-compose.yml for db-agent.
# engine.nix serialises via lib.generators.toYAML, merging compose-defaults.json.
#
# Single service:
#   db-agent — alpine + bash/sqlite/pg/maria/redis/bup baked agent; runs a
#              daily cron-driven backup loop, writes dumps to db-agent-data
#              volume, logs to db-agent-logs volume.
{ buildJson, container }:

let
  app = buildJson.containers.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and the ship
  # engine (native_build type=image-wrapper) packages the code/ tree into a
  # GHCR image. Runtime pulls the published image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    db-agent = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        VM_NAME        = "\${VM_NAME:-unknown}";
        SCHEDULE       = "\${SCHEDULE:-0 3 * * *}";
        NTFY_URL       = "\${NTFY_URL:-http://ntfy:80}";
        NTFY_TOPIC     = "\${NTFY_TOPIC:-backup}";
        RETENTION_DAYS = "\${RETENTION_DAYS:-7}";
        BUP_REMOTE     = "\${BUP_REMOTE:-}";
        TZ             = buildJson.timezone;
      };
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:ro"
        "db-agent-data:/backup"
        "db-agent-logs:/var/log/db-agent"
      ];
      healthcheck = {
        test         = [ "CMD" "test" "-f" "/var/log/db-agent/last-run.json" ];
        interval     = "60s";
        timeout      = "5s";
        retries      = 3;
        start_period = "120s";
      };
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "0.1"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };

  volumes = {
    db-agent-data = { name = "db-agent-data"; };
    db-agent-logs = { name = "db-agent-logs"; };
  };
}
