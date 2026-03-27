{
  description = "Unified Cloud Documentation Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      port = buildJson.ports.app;
    };

    # GHCR image: wraps busybox for static file serving
    ghcr = docker.mkGhcrBuild {
      name = "cloud-spec";
      fromImage = "busybox:latest";
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      site = pkgs.runCommand "cloud-spec-site" {
        nativeBuildInputs = [ pkgs.mdbook ];
      } ''
        mkdir -p build/src
        cp -r ${./docs}/* build/src/
        cp ${./book.toml} build/book.toml
        cd build && mdbook build -d $out
      '';

      compose = docker.mkCompose pkgs {
        banner = docker.banner "~/git/cloud/a_solutions/bc-obs_cloud-spec/src/flake.nix";

        services.cloud-spec = docker.mkService {
          name = "cloud-spec";
          image = ghcr.image;
          build = ghcr.build;
          container_name = "cloud-spec";
          restart = "no";
          networkMode = "host";
          command = "busybox httpd -f -p ${toString config.port} -h /srv";
          volumes = [
            "./site:/srv:ro"
          ];
          skipReadOnly = true;
        };
      };

    in {
      default = pkgs.runCommand "cloud-spec" {} ''
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
