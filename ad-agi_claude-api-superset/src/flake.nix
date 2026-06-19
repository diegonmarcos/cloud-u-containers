{
  description = "claude-api-superset — OpenAI/Ollama/Anthropic mimic over the subscription Claude CLI + vendored Headroom compression (successor to kg-bridge)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-claude-api-superset.json);

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
          # Service-vendored multi-stage Dockerfile (Rust+Python Headroom build →
          # Node front + claude CLI). Same wiring as infra-obs_matomo: point the
          # engine at our Dockerfile so it is copied verbatim to
          # dist/code/<arch>/Dockerfile and the ship engine builds it. Without
          # this the engine generates a single-binary recipe and the multi-stage
          # build is lost (binaries image never pushed).
          dockerfile = ./code/Dockerfile;
          # Sibling build-context the Dockerfile COPYs from. cp -rL'd next to the
          # Dockerfile by the engine. `vendor/` carries the Apache-2.0 Headroom
          # source built with maturin.
          extraFiles = [
            ./code/vendor
            ./code/py
            ./code/server.mjs
            ./code/package.json
            ./code/start.sh
          ];
          cmd       = nb.cmd or "";
          binary    = nb.entrypoint or "";
          baseImage = nb.base_image;
          apt       = nb.apt or "";
        };
        title = "claude-api-superset";
      };
    });
  };
}
