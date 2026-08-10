{
  description = "Paca — AI-native project management (core stack: postgres + valkey + api + web + realtime + nginx gateway) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Derived per-service cloud-data slice (symlink → 1_configs/dist/build-paca.json),
    # produced by cloud-data-config-derive.ts after the service is registered.
    container = builtins.fromJSON (builtins.readFile ./build-paca.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    base_domain =
      lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix {
          inherit buildJson container base_domain;
        };
        # nginx gateway.conf → dist/assets/gateway.conf, mounted by the gateway
        # container (compose volume ./assets/gateway.conf). No nativeBuild: all
        # images are referenced upstream (GHCR mirror = follow-up, see build.json
        # _mirror_todo).
        extraAssets = [
          ./code/nginx/gateway.conf
        ];
        title = "Paca — Project Management (core)";
      };
    });
  };
}
