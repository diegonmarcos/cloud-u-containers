# compose.nix — pure attrset describing docker-compose.yml for cypht.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  app = buildJson.containers.app;
  db  = buildJson.containers.db;

  # Engine wraps upstream cypht/cypht into ghcr.io/diegonmarcos/cypht-binaries.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  port = toString buildJson.ports.app;
in
{
  services = {
    cypht = {
      image = binariesImage;
      container_name = app.container_name;
      # host network: shares lo with co-located maddy + cypht-postgres.
      # → Maddy at 127.0.0.1:993, cypht-postgres at 127.0.0.1:5432 (loopback bind).
      # VM INPUT policy is DROP except 10.0.0.0/24+lo, so :8889 is WG-only.
      network_mode = "host";
      depends_on = {
        cypht-postgres = { condition = "service_healthy"; };
      };
      volumes = [
        "cypht_data:/var/lib/hm3"
        # Cypht's main config. PHP/Nginx process reads this on boot.
        "./configs/cypht.env:/usr/local/share/cypht/.env:ro"
        # Override upstream image's nginx.conf to bind 10.0.0.3:8889 (WG-only)
        # instead of the default 0.0.0.0:80. Defense in depth: matches the
        # Maddy/Stalwart pattern of explicit WG-IP socket binding.
        "./configs/nginx.conf:/etc/nginx/nginx.conf:ro"
        # Override php-fpm pool: TCP :9000 collides with snappymail
        # (both run network_mode: host on oci-mail). Use unix socket.
        # Mount as zzz-* so it loads AFTER zz-docker.conf (which the
        # upstream image uses to force listen=9000) — alphabetic load
        # order, last-wins semantics within the same [www] pool.
        "./configs/php-fpm-www.conf:/usr/local/etc/php-fpm.d/zzz-cypht.conf:ro"
        # Pre-seed accounts assets — mounted RO, copied/used by entrypoint.
        "./assets/seed-accounts.json:/opt/cypht-config/seed-accounts.json:ro"
        "./assets/seed-accounts.sh:/opt/cypht-config/seed-accounts.sh:ro"
        "./configs/seed-accounts.sql:/opt/cypht-config/seed-accounts.sql:ro"
        # Sops-decrypted secrets per-key (env_file at .secrets covers env;
        # individual files at /run/secrets/<KEY> available for any script).
        "./.secrets.d:/run/secrets:ro"
      ];
      env_file = [ ".secrets" ];
      # Seed accounts BEFORE cypht's own entrypoint takes over.
      # Cypht's setup_database.php runs on first request, so we wait for the
      # schema to exist (first GET to / triggers it), then seed.
      entrypoint = [
        "/bin/sh" "-c"
        ("/opt/cypht-config/seed-accounts.sh 2>&1 | sed 's/^/[seed-accounts] /' >&2 || true; "
         + "exec docker-entrypoint.sh")
      ];
      healthcheck = {
        # Healthcheck via WG IP (where nginx is now bound) — 127.0.0.1:port
        # would fail because nginx is bound 10.0.0.3 only.
        test = [ "CMD" "curl" "-sf" "http://10.0.0.3:${port}/" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
        start_period = "20s";
      };
      deploy.resources = {
        limits       = { memory = app.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = app.resources.mem_reservation; };
      };
    };

    cypht-postgres = {
      image = db.image;
      container_name = db.container_name;
      # NOT host network — published on 127.0.0.1:5432 only. cypht (host net)
      # accesses via lo:5432.
      ports = [ "127.0.0.1:5432:5432" ];
      env_file = [ ".secrets" ];
      environment = {
        POSTGRES_DB   = "cypht";
        POSTGRES_USER = "cypht";
        # POSTGRES_PASSWORD comes from .secrets via env_file
      };
      volumes = [
        "cypht_pgdata:/var/lib/postgresql/data"
      ];
      healthcheck = {
        test = [ "CMD-SHELL" "pg_isready -U cypht -d cypht" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
        start_period = "10s";
      };
      deploy.resources = {
        limits       = { memory = db.resources.mem_limit;       cpus = "0.5"; };
        reservations = { memory = db.resources.mem_reservation; };
      };
    };
  };

  volumes = {
    cypht_data   = {};
    cypht_pgdata = {};
  };
}
