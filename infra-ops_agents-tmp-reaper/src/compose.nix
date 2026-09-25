# compose.nix — docker-compose for agents-tmp-reaper.
# engine.nix serialises via lib.generators.toYAML, merging compose-defaults.json.
#
# A scheduled one-shot maintenance container in the db-agent pattern, scoped to
# oci-apps only. It owns NO data of its own beyond a log volume; its one job is
# to periodically reach the AGENT containers' /tmp (their writable layers live
# on the host root filesystem) and clear stale scratch — task 442 / issue 410:
# the agent containers leaked into /tmp at ~2.36 GB/hour and filled the oci-apps
# root filesystem.
#
# SAFETY (the #393 lesson): the scrub is locked to the declared AGENT_CONTAINERS'
# /tmp at STALE_MINUTES of age. It never runs docker prune and never touches a
# container, image, volume or build cache. docker.sock is mounted READ-ONLY and
# the roster is fail-closed (empty AGENT_CONTAINERS does nothing).
#
# No restart policy: it is a scheduled one-shot. `restart` comes only from the
# fleet default ("no") — deliberately not overridden.
{ buildJson, container }:

let
  app = buildJson.containers.app;
in
{
  services = {
    agents-tmp-reaper = {
      image          = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
      container_name = app.container_name;
      network_mode   = "host";
      environment = {
        TZ               = buildJson.timezone;
        # Cron schedule for the daily-ish pass. STALE_MINUTES is how long an
        # entry under an agent's /tmp must have gone untouched before it counts
        # as scrap. AGENT_CONTAINERS is the allow-list; keep it in sync with the
        # agent fleet.
        SCHEDULE         = "\${SCHEDULE:-0 */2 * * *}";
        STALE_MINUTES    = "\${STALE_MINUTES:-180}";
        SCRUB_ROOT       = "\${SCRUB_ROOT:-/tmp}";
        AGENT_CONTAINERS = "\${AGENT_CONTAINERS:-hermes-agent my-ai-api my-ai_claude-api kg-store kg-store-pub session-memory cloud-cgc-pub-mcp}";
      };
      # Read-only host docker socket so the reaper can `docker exec` into the
      # agent containers and clean the /tmp that lives in their writable layers.
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:ro"
        "agents-tmp-reaper-logs:/var/log/agents-tmp-reaper"
      ];
      healthcheck = {
        test     = [ "CMD" "test" "-S" "/var/run/docker.sock" ];
        interval = "5m";
        timeout  = "5s";
        retries  = 2;
        start_period = "30s";
      };
      deploy.resources =
           { limits = { cpus = "0.05"; }; }
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };

  volumes = {
    agents-tmp-reaper-logs = { name = "agents-tmp-reaper-logs"; };
  };
}