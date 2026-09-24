# compose.nix — docker-compose spec for umami (multi-container: app + db + setup).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
#
# Three services (all on the default compose network so service names resolve):
#   umami        — upstream wrapped into <name>-binaries:latest (app, port bound to WG IP)
#   umami-db     — postgres:16-alpine (db, exposed internally only)
#   umami-setup  — curlimages/curl:latest (one-shot configuration job)
{ buildJson, container, containerDb, containerSetup, svc }:

let
  app   = buildJson.containers.app;
  db    = buildJson.containers.db;
  setup = buildJson.containers.setup;

  appPort = toString buildJson.ports.app;
  dbPort  = toString buildJson.ports.db;

  # Engine emits dist/code/<arch>/Dockerfile wrapping buildJson.upstream_image
  # and ships it to GHCR as <name>-binaries:latest. The umami container
  # pulls this image at runtime.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    umami = {
      image = binariesImage;
      container_name = app.container_name;
      # host networking, NOT published ports. The docker daemon runs with
      # iptables = false (vm-pilot container/daemon-firewall.nix), so -p
      # publishing installs no DNAT rule: dockerd holds the socket and
      # never forwards, so the port accepts TCP and then hangs forever.
      # Every working service in the fleet binds the host stack directly.
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        DATABASE_URL      = "postgresql://${db.db_user}:\${DB_PASSWORD}@localhost:${dbPort}/${db.db_name}";  # localhost, not the container name: host networking has no docker DNS
        DATABASE_TYPE     = "postgresql";
        APP_SECRET        = "\${APP_SECRET}";
        PORT              = appPort;
        BASE_PATH         = "/umami";
        DISABLE_TELEMETRY = "1";
      };
      depends_on.${db.container_name} = { condition = "service_healthy"; };
      healthcheck = {
        test     = [ "CMD-SHELL" "curl -sf http://localhost:${appPort}/api/heartbeat || exit 1" ];
        interval = "15s";
        timeout  = "5s";
        retries  = 5;
        # Measured 2026-09-15 on oci-analytics (954MB, memory pressure high):
        # the container started just before 22:52 and first answered the
        # heartbeat at ~22:56. With 30s the compose wait marked it unhealthy
        # after ~105s and failed the ship (run 35032157716) while it was still
        # booting, and umami-setup never ran. A check that passes during
        # start_period marks it healthy at once, so a long window costs a
        # fast start nothing.
        start_period = "600s";
      };
      deploy.resources = {
        # No memory ceiling: build.json declares no limits.memory. A cgroup memory.max
        # is a LOCAL wall that reclaims from this container regardless of host free
        # RAM; pressure is the PSI watchdog's job. Reading the absent attribute is
        # itself an eval error, so do not read it.
        reservations = { memory = app.resources.reservations.memory; };
      };
    };

    "${db.container_name}" = {
      image          = db.image;
      container_name = db.container_name;
      # host networking too: the app resolves it as localhost:${dbPort}, and
      # `expose` is meaningless on the host stack. Postgres is started with
      # -p ${dbPort} (below) so it does not collide with any system postgres.
      network_mode   = "host";
      environment = {
        POSTGRES_DB       = db.db_name;
        POSTGRES_USER     = db.db_user;
        POSTGRES_PASSWORD = "\${DB_PASSWORD}";
        PGPORT            = dbPort;
      };
      command = [ "-p" dbPort ];
      volumes = [ "umami_db_data:/var/lib/postgresql/data" ];
      healthcheck = {
        test     = [ "CMD-SHELL" "pg_isready -U ${db.db_user} -p ${dbPort}" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
      deploy.resources = {
        # No memory ceiling: build.json declares no limits.memory. A cgroup memory.max
        # is a LOCAL wall that reclaims from this container regardless of host free
        # RAM; pressure is the PSI watchdog's job. Reading the absent attribute is
        # itself an eval error, so do not read it.
        reservations = { memory = db.resources.reservations.memory; };
      };
    };

    "${setup.container_name}" = {
      image          = setup.image;
      container_name = setup.container_name;
      # Host networking, exactly like its peers umami and umami-db. Without
      # this the setup job lands on the default bridge network, where
      # http://localhost:3006 inside the container refers to ITSELF, not the
      # app — every auth call gets connection-refused and setup reports
      # outcome=auth-failed even though the configured password is correct
      # and the app is healthy. The app binds the host stack (no published
      # ports; the docker daemon runs iptables=false), so the only way the
      # one-shot job can reach it is to share that stack.
      network_mode   = "host";
      # Root, because the job's one durable output is /output/site_id on the
      # named volume umami_config, and docker creates a named volume root:root
      # 0755. curlimages/curl runs as curl_user (uid 100), so after the site
      # was finally verified (a53333fc) setup died on the very next line —
      # "can't create /output/site_id: Permission denied", measured on
      # oci-analytics 2026-09-24T16:23Z — and configured stayed 0. Same
      # resolution as user-ai_cloud-cgc-pub-mcp's writer. One-shot job, host
      # network, no published port, no-new-privileges still applied.
      user           = "0:0";
      env_file       = [ ".secrets" ];
      depends_on.umami = { condition = "service_healthy"; };
      entrypoint     = [ "/bin/sh" "/setup/setup.sh" ];
      volumes = [
        "./configs/setup.sh:/setup/setup.sh:ro"
        "umami_config:/output"
      ];
    };
  };

  volumes = {
    umami_db_data = { name = "umami_db_data"; };
    umami_config  = { name = "umami_config"; };
  };
}
