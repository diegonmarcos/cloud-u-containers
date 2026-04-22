{
  description = "Dagu - Lightweight DAG-based workflow scheduler — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-dagu.json);
    svc = container.services;

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "base.yaml";      vars = {}; }
          { name = "fetch-token.sh"; vars = {}; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container svc; };
        # Dockerfile + ntfy-bridge.sh + triggers.json + dags/ are bind-mounted /
        # used as docker build context from dist/assets/.
        extraAssets = [
          ./code/Dockerfile
          ./code/ntfy-bridge.sh
          ./triggers.json
          ./dags
        ];
        title = "Dagu - Lightweight DAG-based workflow scheduler";
      };
    });
  };
}
