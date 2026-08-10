{
  description = "CrowdSec — behavioral IDS/IPS engine (DORMANT placeholder) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single-container service → engine derives 1_cloud-configs/dist/build-crowdsec.json
    container = builtins.fromJSON (builtins.readFile ./build-crowdsec.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib  = pkgs.lib;
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        # Dormancy is rendered declaratively from build.json.ports — no hardcoding.
        templates = [
          {
            name = "config.yaml.local";
            vars = {
              LAPI_LISTEN  = "0.0.0.0:${toString buildJson.ports.lapi}";
              METRICS_ADDR = "0.0.0.0";
              METRICS_PORT = toString buildJson.ports.metrics;
            };
          }
          { name = "acquis.yaml"; vars = {}; }
        ];
        composeSpec = import ./compose.nix {
          inherit lib buildJson container;
        };
        title = "CrowdSec — behavioral IDS/IPS engine (dormant)";
      };
    });
  };
}
