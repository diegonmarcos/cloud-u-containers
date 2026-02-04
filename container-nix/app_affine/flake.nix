{
  description = "AFFiNE - Privacy-first workspace (Notion/Miro alternative)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "drive.diegonmarcos.com";
      container_name = "affine";
      image = "ghcr.io/toeverything/affine-graphql:stable";
      port = 3010;
      timezone = "Europe/Madrid";

      # Admin credentials
      admin_email = "admin@diegonmarcos.com";
      admin_password = "CHANGE_ME_ADMIN_PASSWORD";

      # Database
      db_user = "affine";
      db_password = "CHANGE_ME_DB_PASSWORD";
      db_name = "affine";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        affine:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          command: ['sh', '-c', 'node ./scripts/self-host-predeploy && node ./dist/index.js']
          ports:
            - "${toString config.port}:3010"
          depends_on:
            affine-postgres:
              condition: service_healthy
            affine-redis:
              condition: service_healthy
          volumes:
            - ./data/config:/root/.affine/config
            - ./data/storage:/root/.affine/storage
          environment:
            TZ: ${config.timezone}
            NODE_OPTIONS: "--import=./scripts/register.js"
            AFFINE_CONFIG_PATH: /root/.affine/config
            REDIS_SERVER_HOST: affine-redis
            DATABASE_URL: postgres://${config.db_user}:${config.db_password}@affine-postgres:5432/${config.db_name}
            NODE_ENV: production
            AFFINE_ADMIN_EMAIL: ${config.admin_email}
            AFFINE_ADMIN_PASSWORD: ${config.admin_password}
            AFFINE_SERVER_HOST: "0.0.0.0"
            AFFINE_SERVER_PORT: "3010"
            AFFINE_SERVER_HTTPS: "false"
            AFFINE_SERVER_EXTERNAL_URL: https://${config.domain}
            ENABLE_CAPTCHA: "false"
            THROTTLE_TTL: "60"
            THROTTLE_LIMIT: "120"
            AFFINE_STORAGE_PROVIDER: fs
            AFFINE_STORAGE_PATH: /root/.affine/storage
          networks:
            - proxy
            - affine-internal
          healthcheck:
            test: ['CMD-SHELL', 'node ./scripts/health-check.js']
            interval: 30s
            timeout: 10s
            retries: 5
            start_period: 60s

        affine-redis:
          image: redis:7-alpine
          container_name: affine-redis
          restart: unless-stopped
          volumes:
            - ./data/redis:/data
          networks:
            - affine-internal
          healthcheck:
            test: ['CMD', 'redis-cli', 'ping']
            interval: 10s
            timeout: 5s
            retries: 5
          command: redis-server --save 60 1 --loglevel warning

        affine-postgres:
          image: postgres:16-alpine
          container_name: affine-postgres
          restart: unless-stopped
          volumes:
            - ./data/postgres:/var/lib/postgresql/data
          environment:
            POSTGRES_USER: ${config.db_user}
            POSTGRES_PASSWORD: ${config.db_password}
            POSTGRES_DB: ${config.db_name}
            PGDATA: /var/lib/postgresql/data/pgdata
          networks:
            - affine-internal
          healthcheck:
            test: ['CMD-SHELL', 'pg_isready -U ${config.db_user}']
            interval: 10s
            timeout: 5s
            retries: 5

      networks:
        proxy:
          external: true
        affine-internal:
          driver: bridge

      volumes:
        affine-config:
        affine-storage:
        affine-redis:
        affine-postgres:
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "affine-configs" {} ''
        mkdir -p $out/data/{config,storage,redis,postgres}
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose ];
    };
  };
}
