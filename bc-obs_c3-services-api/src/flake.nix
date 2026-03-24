{
  description = "C3 Services REST API — service API gateway Fastify API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    config = {
      container_name = "c3-services-api";
      image = "ghcr.io/diegonmarcos/c3-services-api:latest";
      port = 8082;
    };

    title = "C3 Services REST API";

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_c3-services-api/src/flake.nix";

      services.c3-services-api = docker.mkService {
        name = "c3-services-api";
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";
        skipReadOnly = true;

        env_file = [ ".secrets" ];
        environment = [
          "PORT=${toString config.port}"
          "NODE_ENV=production"
        ];
        healthcheck = {
          test = ''["CMD", "curl", "-f", "http://localhost:${toString config.port}/health"]'';
          interval = "30s";
          timeout = "10s";
          retries = 3;
          start_period = "15s";
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "c3-services-api-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
