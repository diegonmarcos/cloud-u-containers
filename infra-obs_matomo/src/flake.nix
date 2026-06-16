{
  description = "Matomo Hybrid Analytics — dist layout v2 (Type A, own code)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-matomo-hybrid.json);

    engine = import ../../_shared/engine.nix;
    nb = buildJson.docker.native_build;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        nativeBuild = {
          # dockerfile points the shared engine at the service-vendored
          # multi-stage Dockerfile (matomo:fpm-alpine → debian:bookworm-slim
          # wrapper). Without it the engine falls back to Type A flavor (b)
          # which assumes a single-binary COPY — and matomo's Dockerfile
          # is multi-stage. Result was 'No Dockerfile at dist/code/arm64/
          # code/Dockerfile' → ship skipped → matomo-binaries:latest never
          # pushed to GHCR → arm64 VM compose pull 'manifest unknown'.
          dockerfile = ./code/Dockerfile;
          # Sibling directories the Dockerfile COPYs from (scripts/, config/,
          # receiver/). Engine puts them next to the Dockerfile via cp -rL,
          # so the build context matches what the multi-stage RUN+COPY
          # statements expect.
          extraFiles = [
            ./code/scripts
            ./code/config
            ./code/receiver
          ];
          cmd       = nb.cmd or "";
          binary    = nb.entrypoint or "";
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = "Matomo Hybrid Analytics (v2)";
      };
    });
  };
}
