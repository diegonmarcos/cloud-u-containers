{
  description = "OpenClaw — open-source agent gateway (cloud-agi-openclaw), loopback-only on oci-apps behind the fleet agent gateway";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # build-cloud-agi-openclaw.json: cloud-infra's emitter names the generated
    # file after containers.app.container_name (build-${containerName}.json).
    container = builtins.fromJSON (builtins.readFile ./build-cloud-agi-openclaw.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        # configs/openclaw.json is bind-mounted read-only by compose.nix; it MUST
        # be emitted here, or the mount source does not exist on the VM and
        # Docker creates an empty directory in its place (the hermes config.yaml
        # trap, 2026-08-09). JSON: the engine adds no banner to .json files.
        templates = [
          { name = "openclaw.json";
            text = builtins.toJSON (import ./openclaw-config.nix { inherit buildJson; }); }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "OpenClaw";
      };
    });
  };
}
