{
  description = "Photoprism Photo Gallery - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "photos.diegonmarcos.com";
      app_container = "photoprism-app";
      db_container = "photoprism-db";
      app_image = "photoprism/photoprism:latest";
      db_image = "mariadb:11.4";
      app_port = 2342;
      timezone = "Europe/Madrid";

      # Non-secret settings
      admin_user = "admin";
      site_url = "https://photos.diegonmarcos.com";
      db_name = "photoprism";
      db_user = "photoprism";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      services:
        photoprism-app:
          image: ${config.app_image}
          container_name: ${config.app_container}
          restart: unless-stopped
          depends_on:
            - photoprism-db
          security_opt:
            - seccomp:unconfined
            - apparmor:unconfined
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            PHOTOPRISM_ADMIN_USER: ${config.admin_user}
            PHOTOPRISM_SITE_URL: ${config.site_url}
            PHOTOPRISM_ORIGINALS_LIMIT: 5000
            PHOTOPRISM_HTTP_COMPRESSION: gzip
            PHOTOPRISM_DATABASE_DRIVER: mysql
            PHOTOPRISM_DATABASE_SERVER: photoprism-db:3306
            PHOTOPRISM_DATABASE_NAME: ${config.db_name}
            PHOTOPRISM_DATABASE_USER: ${config.db_user}
            PHOTOPRISM_DISABLE_TLS: "true"
            PHOTOPRISM_DEFAULT_TLS: "false"
          ports:
            - "${toString config.app_port}:2342"
          volumes:
            - ./originals:/photoprism/originals
            - ./storage:/photoprism/storage
            - ./import:/photoprism/import
          networks:
            - internal
            - proxy

        photoprism-db:
          image: ${config.db_image}
          container_name: ${config.db_container}
          restart: unless-stopped
          command: --innodb-buffer-pool-size=256M --transaction-isolation=READ-COMMITTED --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --max-connections=512 --innodb-rollback-on-timeout=OFF --innodb-lock-wait-timeout=120
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            MYSQL_DATABASE: ${config.db_name}
            MYSQL_USER: ${config.db_user}
          volumes:
            - ./db:/var/lib/mysql
          networks:
            - internal

      networks:
        internal:
          driver: bridge
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "photoprism-configs" {} ''
        mkdir -p $out/{originals,storage,import,db}
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.sops pkgs.age ];
    };
  };
}
