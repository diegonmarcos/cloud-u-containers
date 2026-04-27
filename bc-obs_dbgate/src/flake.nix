{
  description = "DBGate — Universal database manager — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-dbgate.json);
    # cloud-data-databases.json resolution (2026-04-27):
    #   1. /app/cloud-data-databases.json        — bundled in-image
    #   2. ../../../2_configs/dist/...           — dev: cloud repo dist/
    #   3. ../../../cloud-data/...               — legacy: c3_git_repos clone
    #   4. ../../../cloud-data-databases.json    — legacy: cloud repo root
    dbDataPath =
      if builtins.pathExists /app/cloud-data-databases.json
        then /app/cloud-data-databases.json
      else if builtins.pathExists ../../../2_configs/dist/cloud-data-databases.json
        then ../../../2_configs/dist/cloud-data-databases.json
      else if builtins.pathExists ../../../cloud-data/cloud-data-databases.json
        then ../../../cloud-data/cloud-data-databases.json
      else ../../../cloud-data-databases.json;
    dbData    = builtins.fromJSON (builtins.readFile dbDataPath);

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
