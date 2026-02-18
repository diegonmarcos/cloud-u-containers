{
  description = "SurrealDB Hybrid Knowledge Graph - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "surrealdb";
      image = "surrealdb/surrealdb:v2";
      port = 8001;
      data_path = "/opt/data/surrealdb";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        surrealdb:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          command: start --log info --user root --pass ''${SURREAL_ROOT_PASSWORD} file:/data/surreal.db
          env_file:
            - .secrets
          ports:
            - "127.0.0.1:${toString config.port}:8000"
          volumes:
            - ${config.data_path}:/data
          networks:
            - kg-net
          healthcheck:
            test: ["CMD", "/surreal", "is-ready", "--conn", "http://localhost:8000"]
            interval: 15s
            timeout: 5s
            retries: 3
            start_period: 10s

      networks:
        kg-net:
          driver: bridge
    '';

    mkSchema = pkgs: pkgs.copyPathToStore ./schema.surql;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "kg-graph-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkSchema pkgs} $out/schema.surql
      '';
    });
  };
}
