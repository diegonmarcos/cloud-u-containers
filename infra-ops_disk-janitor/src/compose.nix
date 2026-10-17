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
#   IMAGE_KEEP_PREVIOUS  images in use are always kept, plus this many unused
#                        previous tagged images per repository (the rollback)
#   DANGLING_MIN_AGE_HOURS  untagged images older than this are removed
#   RUNNER_WORK_MIN_AGE_DAYS  idle GitHub runners: _work dirs older than this go,
#                        with their self-update folders and old _diag logs
#   GRADLE_HOME_PATH / GRADLE_MAX_AGE_DAYS  Gradle cache entries unused this long go
#   LANCE_HOMES          cgc LanceDB homes trimmed of superseded manifests and
#                        unreferenced data fragments
# `disk-janitor --aggressive` (docker exec, called by the disk watchdog above 85%)
# drops the age gates; the keep rules and the never-list are unchanged.
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
        IMAGE_KEEP_PREVIOUS       = "\${IMAGE_KEEP_PREVIOUS:-1}";
        DANGLING_MIN_AGE_HOURS    = "\${DANGLING_MIN_AGE_HOURS:-1}";
        RUNNER_WORK_MIN_AGE_DAYS  = "\${RUNNER_WORK_MIN_AGE_DAYS:-3}";
        GRADLE_HOME_PATH          = "\${GRADLE_HOME_PATH:-/vol/my-ai-api-home/toolchain/gradle-home}";
        GRADLE_MAX_AGE_DAYS       = "\${GRADLE_MAX_AGE_DAYS:-30}";
        LANCE_HOMES               = "\${LANCE_HOMES:-/vol/octocode_db /vol/octocode_db_pvt}";
        STAGING_PARENT            = "/vol/host-cache";
        STAGING_MAX_AGE_HOURS     = "\${STAGING_MAX_AGE_HOURS:-24}";
        NPM_CACHE_HOMES           = "\${NPM_CACHE_HOMES:-/vol/claude-superset-api-home}";
        NPM_CACHE_MAX_MB          = "\${NPM_CACHE_MAX_MB:-1024}";
        NPM_CACHE_CONTAINER       = "\${NPM_CACHE_CONTAINER:-cloud-agi-claude}";
        GIT_GC_ROOTS              = "\${GIT_GC_ROOTS:-/vol/cloud-git-gh /vol/octocode_repos}";
        GIT_GC_LOOSE_MB           = "\${GIT_GC_LOOSE_MB:-200}";
        GIT_GC_MAX_PACKS          = "\${GIT_GC_MAX_PACKS:-20}";
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
        # Cache-bearing volumes the janitor trims (never data): the Gradle cache
        # inside my-ai-api-home and the cgc LanceDB homes.
        "my-ai-api-home:/vol/my-ai-api-home"
        "octocode_db:/vol/octocode_db"
        "octocode_db_pvt:/vol/octocode_db_pvt"
        # 2026-10-17: cgc-db restore staging (host ~/.cache), the npm cache in the
        # claude home, and the git clones the janitor `git gc`s (never deletes).
        "/home/ubuntu/.cache:/vol/host-cache"
        "claude-superset-api-home:/vol/claude-superset-api-home"
        "cloud-git-gh:/vol/cloud-git-gh"
        "octocode_repos:/vol/octocode_repos"
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
    # Existing volumes owned by other services (fixed names, same as their own
    # compose files). Not `external`, mirroring cloud-cgc-pub-mcp: a missing one
    # becomes an empty volume and the janitor logs SKIP instead of failing to start.
    my-ai-api-home  = { name = "my-ai-api-home"; };
    octocode_db     = { name = "octocode_db"; };
    octocode_db_pvt = { name = "octocode_db_pvt"; };
    claude-superset-api-home = { name = "claude-superset-api-home"; };
    cloud-git-gh    = { name = "cloud-git-gh"; };
    octocode_repos  = { name = "octocode_repos"; };
  };
}
