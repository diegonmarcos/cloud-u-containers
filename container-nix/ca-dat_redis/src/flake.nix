{
  description = "Redis Cache - In-memory data store";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "redis";
      image = "redis:7-bookworm";
      port = 6379;
      timezone = "Europe/Madrid";

      # Memory settings
      maxmemory = "128mb";
      maxmemory_policy = "allkeys-lru";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        redis:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "127.0.0.1:${toString config.port}:6379"
          env_file:
            - .env
          command: >
            sh -c "redis-server
            --appendonly yes
            --maxmemory ${config.maxmemory}
            --maxmemory-policy ${config.maxmemory_policy}
            --save 60 1
            --loglevel warning
            --requirepass $$REDIS_PASSWORD"
          volumes:
            - ./data:/data
          environment:
            TZ: ${config.timezone}
          networks:
            - proxy
          deploy:
            resources:
              limits:
                memory: 256M
              reservations:
                memory: 64M
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

      networks:
        proxy:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "redis-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
