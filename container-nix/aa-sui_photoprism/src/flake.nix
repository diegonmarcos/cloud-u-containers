{
  description = "PhotoPrism Photo Gallery - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "photos.diegonmarcos.com";
      app_container = "photoprism_app";
      db_container = "photoprism_mariadb";
      rclone_container = "photoprism_rclone";
      app_image = "photoprism/photoprism:latest";
      db_image = "mariadb:11";
      rclone_image = "rclone/rclone:latest";
      app_port = 3013;
      timezone = "Europe/Madrid";
      db_name = "photoprism";
      db_user = "photoprism";
      # OCI Object Storage S3-compatible
      s3_bucket = "my-photos";
      s3_endpoint = "https://axpmn3qtq4ig.compat.objectstorage.eu-marseille-1.oraclecloud.com";
      s3_region = "eu-marseille-1";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # PhotoPrism - AI-powered photo management
      # Deployed on: oci-p-flex_1 (Oracle Flex)
      # Originals mounted from OCI Object Storage via rclone

      services:
        rclone:
          image: ${config.rclone_image}
          container_name: ${config.rclone_container}
          restart: unless-stopped
          cap_add:
            - SYS_ADMIN
          devices:
            - /dev/fuse
          security_opt:
            - apparmor:unconfined
          environment:
            - RCLONE_CONFIG_OCI_TYPE=s3
            - RCLONE_CONFIG_OCI_PROVIDER=Other
            - RCLONE_CONFIG_OCI_ACCESS_KEY_ID=''${OCI_S3_ACCESS_KEY}
            - RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY=''${OCI_S3_SECRET_KEY}
            - RCLONE_CONFIG_OCI_ENDPOINT=${config.s3_endpoint}
            - RCLONE_CONFIG_OCI_REGION=${config.s3_region}
            - RCLONE_CONFIG_OCI_ACL=private
          env_file:
            - .secrets
          volumes:
            - /opt/containers/photoprism/originals:/data:shared
          command: >
            mount oci:${config.s3_bucket}
            /data
            --allow-other
            --allow-non-empty
            --vfs-cache-mode full
            --vfs-cache-max-size 1G
            --vfs-read-chunk-size 32M
            --vfs-read-chunk-size-limit 256M
            --dir-cache-time 5m
            --log-level INFO
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'ls', '/data']
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

        photoprism:
          image: ${config.app_image}
          container_name: ${config.app_container}
          restart: "no"
          ports:
            - "10.0.0.2:${toString config.app_port}:2342"
          volumes:
            - photoprism_storage:/photoprism/storage
            - /opt/containers/photoprism/originals:/photoprism/originals:ro
          environment:
            - PHOTOPRISM_ADMIN_USER=admin
            - PHOTOPRISM_ADMIN_PASSWORD=''${PHOTOPRISM_ADMIN_PASSWORD:-changeme}
            - PHOTOPRISM_AUTH_MODE=password
            - PHOTOPRISM_SITE_URL=https://${config.domain}/
            - PHOTOPRISM_ORIGINALS_LIMIT=5000
            - PHOTOPRISM_HTTP_COMPRESSION=gzip
            - PHOTOPRISM_LOG_LEVEL=info
            - PHOTOPRISM_READONLY=true
            - PHOTOPRISM_EXPERIMENTAL=false
            - PHOTOPRISM_DISABLE_CHOWN=false
            - PHOTOPRISM_DISABLE_WEBDAV=true
            - PHOTOPRISM_DISABLE_SETTINGS=false
            - PHOTOPRISM_DISABLE_TENSORFLOW=false
            - PHOTOPRISM_DISABLE_FACES=false
            - PHOTOPRISM_DISABLE_CLASSIFICATION=false
            - PHOTOPRISM_DISABLE_RAW=false
            - PHOTOPRISM_RAW_PRESETS=false
            - PHOTOPRISM_JPEG_QUALITY=85
            - PHOTOPRISM_DETECT_NSFW=false
            - PHOTOPRISM_UPLOAD_NSFW=true
            - PHOTOPRISM_DATABASE_DRIVER=mysql
            - PHOTOPRISM_DATABASE_SERVER=mariadb:3306
            - PHOTOPRISM_DATABASE_NAME=''${MARIADB_DATABASE:-photoprism}
            - PHOTOPRISM_DATABASE_USER=''${MARIADB_USER:-photoprism}
            - PHOTOPRISM_DATABASE_PASSWORD=''${MARIADB_PASSWORD:-changeme}
          depends_on:
            mariadb:
              condition: service_healthy
            rclone:
              condition: service_healthy
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:2342/api/v1/status']
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 60s

        mariadb:
          image: ${config.db_image}
          container_name: ${config.db_container}
          restart: "no"
          volumes:
            - mariadb_data:/var/lib/mysql
          environment:
            - MARIADB_AUTO_UPGRADE=1
            - MARIADB_INITDB_SKIP_TZINFO=1
            - MARIADB_DATABASE=''${MARIADB_DATABASE:-photoprism}
            - MARIADB_USER=''${MARIADB_USER:-photoprism}
            - MARIADB_PASSWORD=''${MARIADB_PASSWORD:-changeme}
            - MARIADB_ROOT_PASSWORD=''${MARIADB_ROOT_PASSWORD:-changeme}
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'healthcheck.sh', '--connect', '--innodb_initialized']
            interval: 10s
            timeout: 5s
            retries: 5

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        photoprism_storage:
          driver: local
        mariadb_data:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "photoprism-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
