{
  description = "WireGuard Mesh — read-only data-driven control panel (dist layout v2; flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-wireguard-mesh.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;
    nb     = buildJson.docker.native_build;

    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir      = ./.;
        templates   = [];
        composeSpec = import ./compose.nix { inherit buildJson container base_domain; };
        nativeBuild = {
          # Vendored multi-stage Dockerfile (node:20-alpine build → nginx
          # runtime). Engine emits it into dist/code/<arch>/ together with
          # the extraFiles below, so every COPY statement resolves inside
          # the shipped build context. The ship engine auto-detects Type B
          # from the FROM line and builds on the arch-matching runner
          # (arm64 → oci-apps cloud-builder), then pushes
          # wireguard-mesh{,-binaries}:latest to GHCR — the VM only pulls.
          # Same pattern as bc-obs_matomo.
          dockerfile = ./code/Dockerfile;
          extraFiles = [
            ./code/package.json
            ./code/package-lock.json
            ./code/tsconfig.json
            ./code/nginx.conf
            ./code/src
          ];
          cmd       = nb.cmd or "";
          binary    = nb.entrypoint or "";
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title       = "WireGuard Mesh — read-only control panel";
      };
    });
  };
}
