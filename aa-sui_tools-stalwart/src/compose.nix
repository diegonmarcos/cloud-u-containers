# compose.nix — pure attrset describing docker-compose.yml for stalwart.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain, lib }:

let
  app    = buildJson.containers.app;
  sorter = buildJson.containers.sorter;

  # Image name is taken from build.json docker.{registry,image}. Stalwart's
  # docker.image = "stalwart" (no -binaries suffix), so the compose reference
  # must match — not a templated "<name>-binaries". Getting this wrong yields
  # "manifest denied" at compose pull time because the package doesn't exist.
  binariesImage = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
  appPort       = toString app.port;

  # Port mappings driven by extra_ports[].bind in build.json. The `bind` field
  # accepts either a single string ("10.0.0.3") or a list of strings
  # (["10.0.0.3" "10.1.0.3"]) — Phase 4 of the wg-public migration adds the
  # second wg-public bind so Caddy on oci-analytics can reach mail ports via
  # the public-trust mesh (10.1.0.x) without traversing wg0 (10.0.0.x).
  # Format per emitted line: "BIND_IP:HOST_PORT:CONTAINER_PORT".
  bindList = ep:
    let raw = ep.bind or "0.0.0.0"; in
    if builtins.isList raw then raw else [ raw ];

  # extra_ports[].container_port (v0.16 maps offset host port → standard
  # container port; v0.14/v0.15 omitted the field so host == container).
  portMappings = lib.flatten (map (ep:
    let containerPort = ep.container_port or ep.port; in
    map (ip: "${ip}:${toString ep.port}:${toString containerPort}") (bindList ep)
  ) (app.extra_ports or []));
in
{
  services = {
    stalwart = {
      # v0.16.5 migrated bootstrap (data-store-only config.json + JMAP-object
      # settings in RocksDB). config.toml is no longer used in v0.16+.
      # recovery_mode flag in build.json gates STALWART_RECOVERY_{MODE,ADMIN}
      # env vars; flip true for first bootstrap, false for production.
      image          = "stalwartlabs/stalwart:v0.16.5";
      container_name = app.container_name;
      entrypoint     = [ "stalwart" "--config" "/opt/stalwart-mail/etc/config.json" ];
      ports          = portMappings;
      env_file       = [ ".secrets" ];
      environment = {
        TZ = buildJson.timezone;
        # Tells Stalwart what URL clients reach Caddy on so JMAP Session
        # apiUrl/downloadUrl/uploadUrl/eventSourceUrl don't leak the
        # container's internal listener bind port (:2443).
        STALWART_PUBLIC_URL = "https://${buildJson.domain}";
        STALWART_HOSTNAME   = buildJson.domain;
      } // (lib.optionalAttrs (buildJson.recovery_mode or false) {
        # ── RECOVERY-MODE BOOTSTRAP ONLY ──────────────────────────────
        # Set buildJson.recovery_mode = true on FIRST v0.16 boot to wipe
        # settings/quotas/reports/directory and accept admin via the env
        # admin credential below. Then run `stalwart-cli apply` against
        # this container to seed Domain + Account + Listener etc. AFTER
        # successful apply, flip back to false and redeploy — Stalwart
        # boots into production mode with the persisted JMAP-object state.
        STALWART_RECOVERY_MODE  = "1";
        STALWART_RECOVERY_ADMIN = "admin:\${ADMIN_PASSWORD}";
      });
      volumes = [
        "stalwart_data:/opt/stalwart-mail/data"
        # TLS provisioned out-of-band by Caddy (shared with maddy's /opt/containers/maddy/tls)
        "/opt/containers/maddy/tls:/opt/stalwart-mail/tls:ro"
        "./configs/config.json:/opt/stalwart-mail/etc/config.json:ro"
      ];
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
    stalwart-sorter = {
      image          = sorter.image;
      container_name = sorter.container_name;
      entrypoint     = [ "python3" "/app/jmap-sorter.py" ];
      env_file       = [ ".secrets" ];
      environment = {
        JMAP_URL       = "https://localhost:${appPort}";
        RULES_PATH     = "/data/mail-rules.json";
        STARTUP_DELAY  = "20";
      };
      volumes = [
        "./assets/jmap-sorter.py:/app/jmap-sorter.py:ro"
        "./assets/mail-rules.json:/data/mail-rules.json:ro"
      ];
      deploy.resources = {
        limits       = { memory = sorter.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = sorter.resources.mem_reservation; };
      };
    };
  };
  volumes = {
    stalwart_data = {};
  };
}
