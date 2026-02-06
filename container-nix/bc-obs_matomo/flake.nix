{
  description = "Matomo Analytics - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "analytics.diegonmarcos.com";
      app_container = "matomo-app";
      db_container = "matomo-db";
      app_image = "matomo:fpm";
      db_image = "mariadb:11.4";
      app_port = 8080;
      timezone = "Europe/Madrid";
      db_name = "matomo";
      db_user = "matomo";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      services:
        matomo-app:
          image: ${config.app_image}
          container_name: ${config.app_container}
          restart: unless-stopped
          depends_on:
            - matomo-db
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            MATOMO_DATABASE_HOST: matomo-db
            MATOMO_DATABASE_DBNAME: ${config.db_name}
            MATOMO_DATABASE_USERNAME: ${config.db_user}
          volumes:
            - ./html:/var/www/html
          networks:
            - internal
            - proxy

        matomo-db:
          image: ${config.db_image}
          container_name: ${config.db_container}
          restart: unless-stopped
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

        # Nginx sidecar to serve PHP-FPM
        matomo-nginx:
          image: nginx:stable-bookworm
          container_name: matomo-nginx
          restart: unless-stopped
          depends_on:
            - matomo-app
          ports:
            - "${toString config.app_port}:80"
          volumes:
            - ./html:/var/www/html:ro
            - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
          networks:
            - internal
            - proxy

      networks:
        internal:
          driver: bridge
        proxy:
          external: true
    '';

    nginxConf = pkgs.writeText "nginx.conf" ''
      server {
          listen 80;
          server_name _;
          root /var/www/html;
          index index.php;

          location / {
              try_files $uri $uri/ /index.php?$query_string;
          }

          location ~ \.php$ {
              fastcgi_pass matomo-app:9000;
              fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              include fastcgi_params;
          }

          location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
              expires max;
              log_not_found off;
          }
      }
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "matomo-configs" {} ''
        mkdir -p $out/{html,db}
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${nginxConf} $out/nginx.conf
      '';
      docker-compose = dockerCompose;
      nginx-conf = nginxConf;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.mariadb pkgs.sops pkgs.age ];
    };
  };
}
