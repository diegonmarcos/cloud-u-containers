{
  description = "DBGate — Universal database manager — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-dbgate.json);
    # cloud-data-databases.json lives in the tracked submodule at
    # 2_configs/dist/ — read via repo-relative path (nix resolves it
    # from the flake's source tree, no src/ symlink needed).
    dbData    = builtins.fromJSON (builtins.readFile
      ../../../2_configs/dist/cloud-data-databases.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib  = pkgs.lib;
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix {
          inherit lib buildJson container dbData;
        };
        title = "DBGate — Universal Database Manager";
      };
    });
  };
}
