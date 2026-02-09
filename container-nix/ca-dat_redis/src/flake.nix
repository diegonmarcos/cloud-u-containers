{
  description = "Redis Cache - In-memory data store";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "redis";
      image = "redis:alpine";
      maxmemory = "128mb";
      maxmemory_policy = "allkeys-lru";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        redis:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          command: redis-server --appendonly yes --maxmemory ${config.maxmemory} --maxmemory-policy ${config.maxmemory_policy}
          volumes:
            - /data/redis:/data
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 30s
            timeout: 10s
            retries: 3
          networks:
            - dev_network

      networks:
        dev_network:
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
