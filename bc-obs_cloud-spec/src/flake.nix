{
  description = "Unified Cloud Documentation Portal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      port = buildJson.ports.app;
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

      compose = pkgs.writeText "docker-compose.yml" ''
        # ╔══════════════════════════════════════════════════════════════════╗
        # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
        # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
        # ╠══════════════════════════════════════════════════════════════════╣
        # ║ Source: ~/git/cloud/a_solutions/bc-obs_cloud-spec/src/flake.nix ║
        # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_cloud-spec/build.sh ship ║
        # ╚══════════════════════════════════════════════════════════════════╝
        services:
          cloud-spec:
            image: busybox:latest
            container_name: cloud-spec
            restart: unless-stopped
            network_mode: host
            command: busybox httpd -f -p ${toString config.port} -h /srv
            volumes:
              - ./site:/srv:ro
      '';

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
