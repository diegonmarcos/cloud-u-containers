{
  description = "Hermes Agent — Nous Research autonomous agent gateway — dist layout v2 (Type B, wrap upstream)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-hermes-agent.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        # config.yaml is bind-mounted read-only by compose.nix at
        # ./configs/config.yaml (-> /opt/data/config.yaml). It MUST be emitted
        # into dist/configs/ or the bind-mount source path won't exist on the
        # VM and Docker silently creates an EMPTY DIRECTORY there instead —
        # hermes then ignores the whole file (dm_topics, require_mention,
        # allow_from, lean toolset all silently disabled — found 2026-08-09).
        # Passed verbatim (no @VAR@ templating needed): this file has no vars.
        templates = [
          { name = "config.yaml"; text = builtins.readFile ./configs/config.yaml; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Hermes Agent";
      };
    });
  };
}
