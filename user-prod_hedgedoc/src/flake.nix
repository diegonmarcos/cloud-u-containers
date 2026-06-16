{
  description = "HedgeDoc — Real-time collaborative markdown editor — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson   = builtins.fromJSON (builtins.readFile ../build.json);
    container   = builtins.fromJSON (builtins.readFile ./build-hedgedoc_app.json);
    containerDb = builtins.fromJSON (builtins.readFile ./build-hedgedoc_postgres.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container containerDb; };
        title = "HedgeDoc";
      };
    });
  };
}
