# compose.nix — pure attrset describing docker-compose.yml for snappymail.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  app = buildJson.containers.app;

  # Engine wraps the upstream snappymail image into
  # ghcr.io/diegonmarcos/<name>-binaries:latest; at runtime we pull that image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  port = toString buildJson.ports.app;
in
{
  services = {
    snappymail = {
      image = binariesImage;
      container_name = app.container_name;
      # host network: shares lo with co-located maddy (also host-mode) so
      # domain config can use imap_host=<mail.domain>. VM INPUT policy is DROP
      # except 10.0.0.0/24+lo, so :8888 stays reachable only via WG.
      network_mode = "host";
      volumes = [
        "snappymail_data:/var/lib/snappymail"
        # Configs bind-mounted OUTSIDE the data volume (read-only at
        # /opt/snappymail-config/) and copied into the data volume on startup.
        # Direct mounts into /var/lib/snappymail/.../ break the image's
        # entrypoint chown pass.
        "./configs/application.ini:/opt/snappymail-config/application.ini:ro"
        "./configs/domain.ini:/opt/snappymail-config/domain.ini:ro"
        "./configs/live.com.ini:/opt/snappymail-config/live.com.ini:ro"
        "./configs/gmail.com.ini:/opt/snappymail-config/gmail.com.ini:ro"
        "./configs/mail-stalwart.diegonmarcos.com.ini:/opt/snappymail-config/mail-stalwart.diegonmarcos.com.ini:ro"
        # Pre-seed data + PHP executor for additional accounts.
        "./assets/seed-accounts.json:/opt/snappymail-config/seed-accounts.json:ro"
        "./assets/seed-accounts.php:/opt/snappymail-config/seed-accounts.php:ro"
        # Apache `Listen` override — pins to WG IP (container.bind_host),
        # keeping host-net listener off 0.0.0.0.
        "./configs/ports.conf:/etc/apache2/ports.conf:ro"
      ];
      env_file = [ ".secrets" ];
      # NB: `$$` is compose-file escape for a literal `$`. Without it,
      # docker-compose tries to interpolate `$d/$src/$dest` itself and they
      # reach the shell empty.
      entrypoint = [
        "/bin/sh" "-c"
        ("mkdir -p /var/lib/snappymail/_data_/_default_/domains"
         + " /var/lib/snappymail/_data_/_default_/configs;"
         + " cp -f /opt/snappymail-config/application.ini"
         + " /var/lib/snappymail/_data_/_default_/configs/application.ini 2>/dev/null || true;"
         + " for d in domain live.com gmail.com mail-stalwart.diegonmarcos.com; do"
         + "   src=/opt/snappymail-config/$$d.ini;"
         + "   case $$d in domain) dest=/var/lib/snappymail/_data_/_default_/domains/${base_domain}.ini ;;"
         + "     *) dest=/var/lib/snappymail/_data_/_default_/domains/$$d.ini ;;"
         + "   esac;"
         + "   [ -f \"$$src\" ] && cp -f \"$$src\" \"$$dest\" 2>/dev/null || true;"
         + " done;"
         + " php /opt/snappymail-config/seed-accounts.php 2>&1 | sed 's/^/[seed-accounts] /' >&2 || true;"
         + " exec /entrypoint.sh")
      ];
      healthcheck = {
        test = [ "CMD" "curl" "-sf" "http://localhost:${port}/" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "10s";
      };
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
  volumes = {
    snappymail_data = {};
  };
}
