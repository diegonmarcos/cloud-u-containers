{
  description = "Hermes Agent — Nous Research autonomous agent gateway — dist layout v2 (Type B, wrap upstream)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # build-cloud-agi-hermes.json, not build-hermes-agent.json: #542 renamed
    # containers.app.container_name to cloud-agi-hermes, and cloud-infra's
    # emitter derives this generated file's NAME from that value
    # (1_cloud-configs/src/derive/cloud-data-config-derive.ts — `build-${containerName}.json`).
    # So the rename MOVED the target: dist holds build-cloud-agi-hermes.json and
    # no longer holds build-hermes-agent.json. Nix reads from git, so the old
    # spelling reads as "Path ... does not exist in Git repository" — the exact
    # failure claude-api hit in Ship run 35995862469, latent here until hermes
    # next shipped. Guarded now by test_build_json_targets_resolve.
    container = builtins.fromJSON (builtins.readFile ./build-cloud-agi-hermes.json);

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
          # #434: configs/config.yaml is a TEMPLATE, not a finished file — its
          # model line reads @HERMES_MODEL@ and is filled in here from
          # build.json's runtime.model, which is the ONE declaration of the
          # model. It used to carry the literal, which made it a second
          # declaration that silently drifted (it said deepseek/deepseek-v4-pro
          # for weeks while build.json declared v4-flash, and hermes ran the
          # value in THIS file because it reads no OPENAI_MODEL env var).
          # A placeholder rather than a search-and-replace of the old literal on
          # purpose: if this substitution ever stops matching, the container gets
          # a model literally named "@HERMES_MODEL@" and dies at the first
          # request, instead of quietly running a stale pin.
          { name = "config.yaml";
            text = builtins.replaceStrings
              [ "@HERMES_MODEL@" ] [ buildJson.runtime.model ]
              (builtins.readFile ./configs/config.yaml); }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Hermes Agent";
      };
    });
  };
}
