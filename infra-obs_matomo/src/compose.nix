# compose.nix — docker-compose spec for matomo-hybrid (Type A own-code).
# Single container bundling receiver (nginx + php-fpm) + Matomo (nginx +
# php-fpm) + MariaDB, supervised by supervisord. engine.nix serialises this
# attrset via lib.generators.toYAML and merges compose-defaults.json.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  arch = buildJson.docker.arch;
in
{
  services = {
    matomo-hybrid = {
      image = binariesImage;
      container_name = app.container_name;
      # External port → internal 8080 (receiver-nginx default_server).
      # receiver-nginx handles public tracker endpoints and proxies admin
      # traffic to matomo-nginx on 8081 internally.
      # host networking, NOT published ports. The docker daemon runs with
      # iptables = false (vm-pilot container/daemon-firewall.nix), so -p
      # publishing installs no DNAT rule: dockerd holds the socket and never
      # forwards, so the port accepts TCP and then hangs. Every working
      # service in the fleet binds the host stack directly.
      # receiver-nginx listens on 8080, so that is now the HOST port and
      # build.json ports.app must stay 8080 or caddy proxies a dead port.
      network_mode = "host";
      volumes = [
        "matomo_matomo_data:/var/www/html"
        "matomo_matomo_db:/var/lib/mysql"
        "matomo_inbox:/inbox"
      ]
      # Bind the SHIPPED config/ over the copies baked into the image, at the
      # exact paths src/code/Dockerfile COPYs them to.
      #
      # Paths are ./-relative to the PROJECT directory (<remote_path>), not to
      # the compose file that sits in <remote_path>/compose/. Getting that wrong
      # does not fail loudly: docker auto-creates the missing host path as a
      # DIRECTORY, then dies with "are you trying to mount a directory onto a
      # file" and leaves the container in `created` — nothing running, no logs.
      #
      # Without this, editing src/code/config/ does nothing: the deploy faithfully
      # ships those files to <remote_path>/code/<arch>/config/ and the container
      # then ignores them, because the running image carries its own copy from
      # build time. Worse, this service's binaries image has never been pushed to
      # GHCR at all (the package `matomo-binaries` does not exist; `--pull always`
      # 404s and compose silently falls back to a local image from weeks ago), so
      # "rebuild the image" was not in practice a way to change a config either.
      # That is how matomo sat dead for two days with the fix already on disk.
      ++ map (c: "./code/${arch}/config/${c.src}:${c.dst}:ro") [
        { src = "supervisord.conf";   dst = "/etc/supervisor/supervisord.conf"; }
        { src = "receiver-nginx.conf"; dst = "/etc/nginx/sites-available/receiver.conf"; }
        { src = "matomo-nginx.conf";  dst = "/etc/nginx/matomo-nginx.conf"; }
        { src = "receiver-fpm.conf";  dst = "/etc/php/8.2/fpm/receiver-fpm.conf"; }
        { src = "matomo-fpm.conf";    dst = "/etc/php/8.2/fpm/matomo-fpm.conf"; }
        { src = "mariadb.cnf";        dst = "/etc/mysql/mariadb.conf.d/99-matomo.cnf"; }
      ];
      env_file = [ ".secrets" ];
      environment = {
        MATOMO_DATABASE_HOST     = "localhost";
        MATOMO_DATABASE_USERNAME = "\${MATOMO_DB_USER:-matomo}";
        MATOMO_DATABASE_PASSWORD = "\${MATOMO_DB_PASSWORD:-MatomoDB2025!}";
        MATOMO_DATABASE_DBNAME   = "\${MATOMO_DB_NAME:-matomo}";
        MATOMO_API_TOKEN         = "\${MATOMO_API_TOKEN}";
      };
      deploy.resources = {
        # No memory ceiling: build.json declares no limits.memory. A cgroup memory.max
        # is a LOCAL wall that reclaims from this container regardless of host free
        # RAM; pressure is the PSI watchdog's job. Reading the absent attribute is
        # itself an eval error, so do not read it.
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
  };
  volumes = {
    matomo_matomo_data = { name = "matomo_matomo_data"; };
    matomo_matomo_db   = { name = "matomo_matomo_db"; };
    matomo_inbox       = { name = "matomo_inbox"; };
  };
}
