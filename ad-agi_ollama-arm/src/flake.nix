{
  description = "Ollama LLM Server (ARM CPU, 7b models) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-ollama-arm.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # ── Runtime data (data-driven, no hardcoding) ──────────────────
    svc         = container.services;
    app         = buildJson.containers.app;
    # ollama-arm deploys to oci-apps-2 (not yet provisioned); fall back
    # to 0.0.0.0 when the service entry is absent from cloud-data so the
    # flake evaluates cleanly while the VM is pending.
    wg_ip       = (svc."ollama-arm" or { ip = "0.0.0.0"; }).ip;
    api_port    = buildJson.ports.app;
    containerNm = app.container_name;

    # Models pulled at first start; Q4, CPU-optimized 7b models
    models = [
      "deepseek-r1:7b"
      "qwen2.5:7b"
    ];

    modelsPull = lib.concatMapStringsSep "\n" (m: ''
      echo "  Pulling ${m}..."
      docker exec ${containerNm} ollama pull ${m}'') models;

    startupVars = {
      CONTAINER_NAME = containerNm;
      WG_IP          = wg_ip;
      API_PORT       = toString api_port;
      MODELS_PULL    = modelsPull;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "startup.sh"; vars = startupVars; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Ollama LLM Server (ARM CPU)";
      };
    });
  };
}
