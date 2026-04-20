{
  description = "GDELT News Aggregator — Fastify API with SQLite cache";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    buildContainer = builtins.fromJSON (builtins.readFile ./build-news-gdelt.json);
    svc = buildContainer.services;
    vmIp = svc."news-gdelt".ip or "10.0.0.6";  # oci-apps WG IP

    config = {
      container_name = buildContainer.container.container_name;
      image = buildContainer.container.image;
      port = buildJson.ports.app;
      timezone = buildJson.timezone;
    };

    title = buildJson.description;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_news-gdelt/src/flake.nix";

      services.${config.container_name} = docker.mkService {
        name = config.container_name;
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";
        portEnv = ports.envFor "app";

        environment = [
          "NODE_ENV=production"
          "CACHE_DIR=/app/cache"
          "FETCH_INTERVAL=900"
          "TZ=${config.timezone}"
          "BASE_PATH=/news"
          "PORT=${toString config.port}"
        ];
        volumes = [
          "news_gdelt_cache:/app/cache"
        ];
        healthcheck = {
          test = ''["CMD-SHELL", "node -e \"require('http').get('http://${vmIp}:${toString config.port}/health', r => { process.exit(r.statusCode === 200 ? 0 : 1) }).on('error', () => process.exit(1))\""]'';
          interval = "30s";
          timeout = "10s";
          retries = 3;
          start_period = "15s";
        };
      };

      volumes.news_gdelt_cache = {};
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "${config.container_name}-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
