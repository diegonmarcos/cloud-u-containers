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
        # Type A: build the REAL Dockerfile (FROM ghcr.io/dagucloud/dagu:2.5.0,
        # multi-arch) so the shipped image matches the deploy host's arch. Without
        # this the engine emits a Type-B stub `FROM ghcr.io/diegonmarcos/dagu:latest`
        # — it re-wraps dagu's own previous image, freezing the arch at amd64 and
        # crashing on aarch64 oci-apps ("exec format error"). extraFiles are the
        # only files the Dockerfile bakes (the rest — dags/base.yaml/fetch-token.sh
        # — arrive via compose bind-mounts, so they're NOT COPYed).
        nativeBuild = {
          dockerfile = ./code/Dockerfile;
          extraFiles = [ ./code/ntfy-bridge.sh ./triggers.json ];
        };
        title = "Dagu - Lightweight DAG-based workflow scheduler";
      };
    });
  };
}
