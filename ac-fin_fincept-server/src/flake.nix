{
  description = "Fincept Terminal backend — REST + WebSocket over DataHub";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    title = "Fincept Terminal backend — REST + WebSocket";

    # Docker image: built by GHA workflow from fincept-rs Dockerfile and
    # pushed to GHCR. This flake only assembles the compose file.
    ghcr = docker.mkGhcrBuild {
      name = "fincept-server";
      fromImage = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
    };

    config = {
      domain = buildJson.domain;
      container_name = buildJson.containers.app.container_name;
      image = ghcr.image;
      port = buildJson.ports.app;
    };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/ac-fin_fincept-server/src/flake.nix";

      services.fincept-server = docker.mkService {
        name = "fincept-server";
        image = config.image;
        build = ghcr.build;
        container_name = config.container_name;
        networkMode = "host";
        portEnv = ports.envFor "app";

        environment = {
          FINCEPT_PORT = toString config.port;
          RUST_LOG = "info,tower_http=info";
        };
        volumes = [];
        memLimit = "512M";
        memReservation = "128M";
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "fincept-server-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
