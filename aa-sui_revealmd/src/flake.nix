{
  description = "RevealMD - Markdown to reveal.js presentations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    buildContainer = builtins.fromJSON (builtins.readFile ./build-revealmd_app.json);

    config = {
      domain = buildJson.domain;
      container_name = buildContainer.container.container_name;
      image = buildJson.upstream_image;
      port = buildJson.ports.app;
    };

    title = "RevealMD - Markdown to reveal.js presentations";

    ghcr = docker.mkGhcrBuild {
      name = "revealmd";
      fromImage = config.image;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_revealmd/src/flake.nix";
        services = {
          revealmd = docker.mkService {
            name = "revealmd";
            image = ghcr.image;
            build = ghcr.build;
            container_name = config.container_name;
            restart = "no";
            skipReadOnly = true;
            volumes = [
              "slides_data:/slides"
            ];
            command = "/slides --watch --port ${toString config.port}";
            healthcheck = {
              test = "['CMD', 'wget', '-q', '--spider', 'http://localhost:${toString config.port}']";
              interval = "30s";
              timeout = "10s";
              retries = 3;
            };
          };
        };
        volumes = {
          slides_data = {};
        };
      };

      defaultPkg = pkgs.runCommand "revealmd-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
