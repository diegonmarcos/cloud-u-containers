{
  description = "Unified Cloud Documentation Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    lib = nixpkgs.lib;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-cloud-spec.json (symlink → I_cloud-data/).
    # Engine resolves symlink before nix build.
    buildContainer = builtins.fromJSON (builtins.readFile ./build-cloud-spec.json);

    config = {
      container_name = buildContainer.container.container_name;
      port = buildContainer.container.port;
      # Static-serve command template: %PORT% is substituted with the declared port
      command =
        lib.replaceStrings [ "%PORT%" ] [ (toString buildContainer.container.port) ]
          buildJson.runtime.command;
    };

    title = buildJson.description;

    # GHCR image: wraps base image for static file serving
    # Base image declared in build.json (docker.from_image)
    ghcr = docker.mkGhcrBuild {
      name = buildJson.name;
      fromImage = buildJson.docker.from_image;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      site = pkgs.runCommand "${config.container_name}-site" {
        nativeBuildInputs = [ pkgs.mdbook ];
      } ''
        mkdir -p build/src
        cp -r ${./docs}/* build/src/
        cp ${./book.toml} build/book.toml
        cd build && mdbook build -d $out
      '';

      compose = docker.mkCompose pkgs {
        banner = docker.banner "~/git/cloud/a_solutions/bc-obs_cloud-spec/src/flake.nix";

        services.${config.container_name} = docker.mkService {
          name = config.container_name;
          image = ghcr.image;
          build = ghcr.build;
          container_name = config.container_name;
          restart = "no";
          networkMode = "host";
          command = config.command;
          volumes = [
            "./site:/srv:ro"
          ];
          skipReadOnly = true;
        };
      };

    in {
      default = pkgs.runCommand config.container_name {} ''
        mkdir -p $out
        cp -r ${site}/* $out/
        # Flatten: move html/ contents to site/ for compose mount
        mkdir -p $out/site
        if [ -d ${site}/html ]; then
          cp -r ${site}/html/* $out/site/
        else
          cp -r ${site}/* $out/site/
        fi
        cp ${compose} $out/docker-compose.yml
      '';
    });
  };
}
