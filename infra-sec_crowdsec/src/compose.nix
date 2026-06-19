# compose.nix — docker-compose spec for CrowdSec (single container, DORMANT).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json (init:true, restart:no, pids cap, logging…).
#
# DORMANT by construction (LAPI-only):
#   • DISABLE_AGENT=true              → the log processor never runs; nothing is
#                                       acquired, parsed, or detected. CrowdSec
#                                       FATALs on an empty acquisition, so the
#                                       agent is disabled rather than fed no data.
#   • DISABLE_ONLINE_API=true         → no CAPI enrolment / signal sharing / blocklist
#   • no bouncers declared anywhere   → nothing is ever remediated
# The Local API stays up to front crowdsec.diegonmarcos.com. To activate later:
# set DISABLE_AGENT=false, populate acquis.yaml (e.g. Caddy logs), wire a bouncer.
{ lib, buildJson, container }:

let
  app = buildJson.containers.app;

  # Engine emits dist/code/<arch>/Dockerfile wrapping buildJson.upstream_image
  # (Type B) and ships it to GHCR as <name>-binaries:latest. We keep the
  # upstream entrypoint (docker_start.sh) so the image still bootstraps its
  # default parsers/scenarios into the crowdsec_config volume on first run.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  metricsPort = toString buildJson.ports.metrics;
in
{
  services.crowdsec = {
    image = binariesImage;
    container_name = app.container_name;
    network_mode = "host";

    environment = {
      # Dormant = LAPI-only. CrowdSec's agent (log processor) FATALs on boot with
      # "no datasource enabled" when acquisition is empty, so we disable the agent
      # entirely: the Local API stays up (fronts crowdsec.diegonmarcos.com) but
      # nothing is acquired, parsed, or detected. To activate later: set
      # DISABLE_AGENT=false, populate acquis.yaml, and wire a bouncer.
      DISABLE_AGENT      = "true";
      # Never reach the central API (no CAPI enrolment / signal sharing / blocklist).
      DISABLE_ONLINE_API = "true";
      TZ = buildJson.timezone;
    };

    volumes = [
      "crowdsec_config:/etc/crowdsec"
      "crowdsec_data:/var/lib/crowdsec/data"
      # Non-fragile overrides bind-mounted over the volume-populated defaults:
      #   config.yaml.local → CrowdSec deep-merges *.local over config.yaml
      #     (only sets listen_uri + prometheus; does NOT replace the full config)
      #   acquis.yaml       → empty, so no data sources are acquired
      "./configs/config.yaml.local:/etc/crowdsec/config.yaml.local:ro"
      "./configs/acquis.yaml:/etc/crowdsec/acquis.yaml:ro"
    ];

    # cscli ships inside the image and needs no network/registration — proves
    # the container is alive without asserting any (dormant) detection function.
    healthcheck = {
      test     = [ "CMD" "cscli" "version" ];
      interval = "30s";
      timeout  = "10s";
      retries  = 3;
      start_period = "20s";
    };

    deploy.resources = {
      limits       = { memory = app.resources.limits.memory; };
      reservations = { memory = app.resources.reservations.memory; };
    };
  };

  volumes = {
    crowdsec_config = { name = "crowdsec_config"; };
    crowdsec_data   = { name = "crowdsec_data"; };
  };
}
