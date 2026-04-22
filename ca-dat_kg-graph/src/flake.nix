{
  description = "SurrealDB Hybrid Knowledge Graph — dist layout v2 (Type B, wrap upstream)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-surrealdb.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          # SurrealDB schema — SQL init, no variable substitution.
          # SurrealDB v2 accepts '#' as a line-comment prefix, so the
          # engine's default banner prefix renders as valid SQL.
          { name = "schema.surql"; vars = {}; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "SurrealDB Hybrid Knowledge Graph";
      };
    });
  };
}
