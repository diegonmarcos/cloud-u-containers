{
  description = "mail-puller — Rust sidecar that pulls from external IMAP (Gmail/Live) via IDLE and fan-delivers into Maddy + Stalwart (dist layout v2, flake as orchestrator).";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-mail-puller.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    initShVars = {
      # Currently no @VAR@ substitutions in init.sh; envsubst at runtime.
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init.sh"; vars = initShVars; }
        ];
        # sources.json is the declarative source-of-truth at runtime
        # (which mailboxes to pull, which local targets to deliver to).
        # Secrets (OAuth client-id/secret, refresh-tokens) arrive via .secrets.
        extraAssets = [
          ./sources.json
        ];
        # Type A (own code). The actual cargo build happens in the ship
        # docker step (via build.json#docker.native_build.cmd). Here we only
        # declare the resulting binary + base image so the engine emits the
        # right code/<arch>/Dockerfile.
        nativeBuild = {
          baseImage = "debian:bookworm-slim";
          apt       = "ca-certificates libssl3";
          binary    = "mail-puller";
        };
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Mail Puller — IDLE sidecar";
      };
    });
  };
}
