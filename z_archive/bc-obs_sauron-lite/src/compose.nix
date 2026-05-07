# compose.nix — pure attrset describing docker-compose.yml for sauron-lite.
# engine.nix serialises via lib.generators.toYAML, merging compose-defaults.json.
#
# Two services:
#   sauron    — alpine + bash/yara baked scanner, watches /etc + /home (ro)
#   forwarder — tails sauron_logs volume, ships alerts over TCP to central
{ buildJson, container }:

let
  app       = buildJson.containers.app;
  forwarder = buildJson.containers.forwarder;
  central   = buildJson.central;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and the ship
  # engine (native_build type=image-wrapper) packages the code/ tree into a
  # GHCR image. At runtime both services pull the published image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    sauron = {
      image = binariesImage;
      container_name = app.container_name;
      hostname = "sauron-\${VM_NAME:-unknown}";
      volumes = [
        "/etc:/watch/etc:ro"
        "/home:/watch/home:ro"
        "sauron_logs:/var/log/sauron"
        "sauron_queue:/var/spool/sauron"
      ];
      environment = {
        TZ          = buildJson.timezone;
        VM_NAME     = "\${VM_NAME:-unknown}";
        WATCH_DIRS  = "/watch/etc /watch/home";
        QUEUE_FILE  = "/var/spool/sauron/scan-queue.txt";
        ALERTS_FILE = "/var/log/sauron/alerts.jsonl";
        RULES_DIR   = "/etc/sauron/yara-rules";
      };
      healthcheck = {
        test     = [ "CMD" "pgrep" "-f" "inotifywait" ];
        interval = "60s";
        timeout  = "5s";
        retries  = 3;
      };
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "0.25"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };

    forwarder = {
      image = "alpine:3.19";
      container_name = forwarder.container_name;
      depends_on.sauron.condition = "service_started";
      entrypoint = [
        "/bin/sh" "-c"
        (
          "apk add --no-cache netcat-openbsd && "
          + "echo \"Forwarding alerts to $$CENTRAL_HOST:$$CENTRAL_PORT\" && "
          + "tail -F /var/log/sauron/alerts.jsonl 2>/dev/null | "
          + "while read line; do echo \"$$line\" | nc -w1 $$CENTRAL_HOST $$CENTRAL_PORT 2>/dev/null || true; done"
        )
      ];
      volumes = [ "sauron_logs:/var/log/sauron:ro" ];
      environment = {
        TZ           = buildJson.timezone;
        CENTRAL_HOST = central.host;
        CENTRAL_PORT = toString central.port;
      };
      deploy.resources = {
        limits       = { memory = "16m"; cpus = "0.05"; };
        reservations = { memory = "8m";  };
      };
    };
  };

  volumes = {
    sauron_logs  = {};
    sauron_queue = {};
  };
}
