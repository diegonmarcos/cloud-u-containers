{
  description = "Code Server (VS Code in browser) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-code-server.json (symlink → 2_configs/dist/
    # build-code-server.json). Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-code-server.json);

    config = {
      domain = buildJson.domain;
      container_name = buildContainer.container.container_name;
      port = buildJson.ports.app;
      timezone = buildJson.timezone;
    };

    title = "Code Server (VS Code in browser)";

    ghcr = docker.mkGhcrBuild {
      name = "code-server";
      fromImage = buildJson.upstream_image;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      dockerCompose = docker.mkCompose pkgs {
        banner = docker.banner "aa-sui_code-server/src/flake.nix";
        volumes = {
          code_server_config = {};
        };
        services = {
          code-server = docker.mkService {
            name = "code-server";
            image = ghcr.image;
            build = ghcr.build;
            container_name = config.container_name;
            ports = [ "${toString config.port}:8443" ];
            volumes = [
              "code_server_config:/config"
              "/home/ubuntu/workspace:/workspace"
            ];
            environment = {
              TZ = config.timezone;
              PUID = "1000";
              PGID = "1000";
              DEFAULT_WORKSPACE = "/workspace";
            };
            skipReadOnly = true;
          };
        };
      };

      defaultPkg = pkgs.runCommand "code-server-configs" {} ''
        mkdir -p $out
        cp ${dockerCompose} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
