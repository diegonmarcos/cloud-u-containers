# compose.nix — pure attrset describing docker-compose.yml for photoprism.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  app    = buildJson.containers.app;
  db     = buildJson.containers.db;
  rclone = buildJson.containers.rclone;

  # Engine wraps upstream images into per-service GHCR binaries images.
  # The app container uses the binaries image; sidecars (db, rclone) reference
  # upstream images directly (engine emits one code/<arch>/Dockerfile per svc).
  appImage    = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  dbImage     = db.image;
  rcloneImage = rclone.image;
in
{
  services = {
    mariadb = {
      image = dbImage;
      container_name = db.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        MARIADB_AUTO_UPGRADE      = "1";
        MARIADB_INITDB_SKIP_TZINFO = "1";
        MARIADB_DATABASE      = "\${MARIADB_DATABASE:-${buildJson.db.name}}";
        MARIADB_USER          = "\${MARIADB_USER:-${buildJson.db.user}}";
        MARIADB_PASSWORD      = "\${MARIADB_PASSWORD:-changeme}";
        MARIADB_ROOT_PASSWORD = "\${MARIADB_ROOT_PASSWORD:-changeme}";
      };
      volumes = [ "mariadb_data:/var/lib/mysql" ];
      healthcheck = {
        test = [ "CMD" "healthcheck.sh" "--connect" "--innodb_initialized" ];
        interval = "10s";
        timeout  = "5s";
        retries  = 5;
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };

    rclone = {
      image = rcloneImage;
      container_name = rclone.container_name;
      network_mode = "host";
      command = "mount oci:${buildJson.s3.bucket} /data --allow-other --allow-non-empty --vfs-cache-mode full --vfs-cache-max-size 1G --vfs-read-chunk-size 32M --vfs-read-chunk-size-limit 256M --dir-cache-time 5m --log-level INFO";
      env_file = [ ".secrets" ];
      environment = {
        RCLONE_CONFIG_OCI_TYPE              = "s3";
        RCLONE_CONFIG_OCI_PROVIDER          = "Other";
        RCLONE_CONFIG_OCI_ACCESS_KEY_ID     = "\${OCI_S3_ACCESS_KEY}";
        RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY = "\${OCI_S3_SECRET_KEY}";
        RCLONE_CONFIG_OCI_ENDPOINT          = buildJson.s3.endpoint;
        RCLONE_CONFIG_OCI_REGION            = buildJson.s3.region;
        RCLONE_CONFIG_OCI_ACL               = "private";
      };
      volumes = [ "/opt/containers/photoprism/originals:/data:shared" ];
      healthcheck = {
        test = [ "CMD" "ls" "/data" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
        start_period = "15s";
      };
      cap_add = [ "SYS_ADMIN" ];
      privileged = true;
      devices = [ "/dev/fuse" ];
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };

    photoprism = {
      image = appImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        TZ                              = buildJson.timezone;
        PHOTOPRISM_ADMIN_USER           = "admin";
        PHOTOPRISM_ADMIN_PASSWORD       = "\${PHOTOPRISM_ADMIN_PASSWORD:-changeme}";
        PHOTOPRISM_AUTH_MODE            = "password";
        PHOTOPRISM_SITE_URL             = "https://${buildJson.domain}/";
        PHOTOPRISM_ORIGINALS_LIMIT      = "5000";
        PHOTOPRISM_HTTP_COMPRESSION     = "gzip";
        PHOTOPRISM_LOG_LEVEL            = "info";
        PHOTOPRISM_READONLY             = "true";
        PHOTOPRISM_EXPERIMENTAL         = "false";
        PHOTOPRISM_DISABLE_CHOWN        = "false";
        PHOTOPRISM_DISABLE_WEBDAV       = "true";
        PHOTOPRISM_DISABLE_SETTINGS     = "false";
        PHOTOPRISM_DISABLE_TENSORFLOW   = "false";
        PHOTOPRISM_DISABLE_FACES        = "false";
        PHOTOPRISM_DISABLE_CLASSIFICATION = "false";
        PHOTOPRISM_DISABLE_RAW          = "false";
        PHOTOPRISM_RAW_PRESETS          = "false";
        PHOTOPRISM_JPEG_QUALITY         = "85";
        PHOTOPRISM_DETECT_NSFW          = "false";
        PHOTOPRISM_UPLOAD_NSFW          = "true";
        PHOTOPRISM_DATABASE_DRIVER      = "mysql";
        # Service-name resolution on the default compose network (was
        # `localhost`, which resolves to app's own loopback under bridge
        # networking → ECONNREFUSED → exit 100). `mariadb` matches the
        # sibling service name declared at line 19.
        PHOTOPRISM_DATABASE_SERVER      = "mariadb:3306";
        PHOTOPRISM_HTTP_PORT            = toString buildJson.ports.app;
      };
      volumes = [
        "photoprism_storage:/photoprism/storage"
        "/opt/containers/photoprism/originals:/photoprism/originals:ro"
      ];
      depends_on = {
        mariadb = { condition = "service_healthy"; };
        rclone  = { condition = "service_healthy"; };
      };
      healthcheck = {
        test = [ "CMD-SHELL" "wget -qO /dev/null http://127.0.0.1:${toString buildJson.ports.app}/api/v1/status" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
        start_period = "60s";
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };

  volumes = {
    mariadb_data = {};
    photoprism_storage = {};
  };
}
