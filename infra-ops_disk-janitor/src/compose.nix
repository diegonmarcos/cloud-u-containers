# compose.nix — docker-compose for disk-janitor (#811).
# engine.nix serialises via lib.generators.toYAML, merging compose-defaults.json.
#
# Scheduled maintenance container (agents-tmp-reaper / db-agent pattern) that
# keeps the oci-apps root filesystem from filling. 2026-10-03: the box sat at
# 94-95% and a manual image prune was the only thing that bought room.
#
# The POLICY is declared here as env so it is reviewable in source:
#   MODE                 dry-run (report only) | enforce (delete). Enforce since
#                        the first live dry-run pass (2026-10-03) selected only
#                        6 anonymous volumes and kept all 6 dirty _work slots.
#   IMAGE_MIN_AGE_HOURS  an unused image must be at least this old
#   IMAGE_KEEP_PER_REPO  newest K images per repository are always kept
#   BUILD_CACHE_MIN_AGE_HOURS  builder cache older than this is pruned
#   VOLUME_MIN_AGE_DAYS  an ANONYMOUS (64-hex, no compose label) dangling volume
#                        must be this old. Named volumes are NEVER removed.
#   DISPATCH_CONTAINERS  "container:engine" pairs whose _work slots are swept
#                        with the dispatcher's own reap.sh (keeps unpushed work)
#   LOG_RETENTION_DAYS   dispatch logs older than this are removed
#   ALERT_FREE_GB        ntfy alert when host / has less free space than this
#
# SAFETY (#393): never `docker system prune`, never `-f` on rmi (an image a
# container references cannot be removed), never a named volume.
# Host / is mounted READ-ONLY purely to measure free space.
{ buildJson, container }:

let
  app = buildJson.containers.app;
in
{
  services = {
    disk-janitor = {
      image          = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
      container_name = app.container_name;
      network_mode   = "host";
      environment = {
        TZ                        = buildJson.timezone;
        SCHEDULE                  = "\${SCHEDULE:-17 */3 * * *}";
        MODE                      = "\${MODE:-enforce}";
        IMAGE_MIN_AGE_HOURS       = "\${IMAGE_MIN_AGE_HOURS:-24}";
        IMAGE_KEEP_PER_REPO       = "\${IMAGE_KEEP_PER_REPO:-2}";
        BUILD_CACHE_MIN_AGE_HOURS = "\${BUILD_CACHE_MIN_AGE_HOURS:-48}";
        VOLUME_MIN_AGE_DAYS       = "\${VOLUME_MIN_AGE_DAYS:-7}";
        DISPATCH_CONTAINERS       = "\${DISPATCH_CONTAINERS:-cloud-agi-claude:claude}";
        DISPATCH_ROOT             = "\${DISPATCH_ROOT:-/home/appuser/git}";
        REAP_SCRIPT               = "\${REAP_SCRIPT:-/home/appuser/git/cloud-u-containers/_dispatch/reap.sh}";
        LOG_RETENTION_DAYS        = "\${LOG_RETENTION_DAYS:-30}";
        ALERT_FREE_GB             = "\${ALERT_FREE_GB:-12}";
        NTFY_URL                  = "\${NTFY_URL:-http://10.0.0.6:8090}";
        NTFY_TOPIC                = "\${NTFY_TOPIC:-health_resources}";
        HOST_ROOT                 = "/host";
      };
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "/:/host:ro"
        "disk-janitor-logs:/var/log/disk-janitor"
      ];
      healthcheck = {
        test     = [ "CMD" "test" "-S" "/var/run/docker.sock" ];
        interval = "5m";
        timeout  = "5s";
        retries  = 2;
        start_period = "30s";
      };
      deploy.resources =
           { limits = { cpus = "0.10"; }; }
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };

  volumes = {
    disk-janitor-logs = { name = "disk-janitor-logs"; };
  };
}
