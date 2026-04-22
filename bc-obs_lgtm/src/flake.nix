{
  description = "LGTM Stack (Grafana, Loki, Tempo, Mimir) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson  = builtins.fromJSON (builtins.readFile ../build.json);
    cGrafana   = (builtins.fromJSON (builtins.readFile ./build-lgtm_grafana.json)).container;
    cLoki      = (builtins.fromJSON (builtins.readFile ./build-lgtm_loki.json)).container;
    cTempo     = (builtins.fromJSON (builtins.readFile ./build-lgtm_tempo.json)).container;
    cMimir     = (builtins.fromJSON (builtins.readFile ./build-lgtm_mimir.json)).container;

    # Service connections map (embedded in per-container JSONs, identical across all)
    svc = (builtins.fromJSON (builtins.readFile ./build-lgtm_grafana.json)).services;

    engine = import ../../_shared/engine.nix;

    # Grafana is the "app" container for engine's manifest conventions.
    container = {
      container = cGrafana;
      services  = svc;
    };

    templateVars = {
      DOMAIN           = buildJson.domain;
      GRAFANA_PORT     = toString buildJson.ports.grafana;
      LOKI_PORT        = toString buildJson.ports.loki;
      TEMPO_PORT       = toString buildJson.ports.tempo;
      MIMIR_PORT       = toString buildJson.ports.mimir;
      LGTM_IP          = svc.lgtm.ip;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "tempo.yaml";      vars = templateVars; }
          { name = "mimir.yaml";      vars = templateVars; }
          { name = "datasources.yml"; vars = templateVars; }
        ];
        composeSpec = import ./compose.nix {
          inherit buildJson cGrafana cLoki cTempo cMimir svc;
        };
        title = "LGTM Stack — Grafana Labs Observability";
      };
    });
  };
}
