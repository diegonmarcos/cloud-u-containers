{
  description = "C3 Services REST API — service API gateway Fastify API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-c3-services-api.json (symlink → I_cloud-data/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-c3-services-api.json);
    svc = buildContainer.services;

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      port = buildContainer.container.port;
    };

    title = buildJson.description;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_c3-services-api/src/flake.nix";

      services.${config.container_name} = docker.mkService {
        name = config.container_name;
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";
        skipReadOnly = true;
        portEnv = ports.envFor "app";

        env_file = [ ".secrets" ];
        environment = [
          "HOST=${svc."c3-services-api".ip}"
          "NODE_ENV=production"
        ];
        healthcheck = {
          test = ''["CMD", "curl", "-f", "http://${svc."c3-services-api".ip}:${toString config.port}/health"]'';
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
      defaultPkg = pkgs.runCommand "${config.container_name}-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
