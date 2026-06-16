{
  description = "Ollama LLM Server — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-ollama.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    svc         = container.services;
    wgIp        = svc.ollama.ip;
    apiPort     = toString buildJson.ports.app;
    appName     = buildJson.containers.app.container_name;

    # Q8 model variants to preload on first boot. Source of truth is
    # build.json.models; flake keeps the Q8 suffix mapping minimal.
    models = buildJson.models or [
      "deepseek-r1:14b-qwen-distill-q8_0"
      "MFDoom/deepseek-r1-tool-calling:14b-qwen-distill-q8_0"
      "qwen2.5:14b-instruct-q8_0"
    ];

    pullCmds =
      lib.concatMapStringsSep "\n" (m:
        "echo \"  Pulling ${m}...\"\ndocker exec ${appName} ollama pull ${m}"
      ) models;

    templateVars = {
      CONTAINER_NAME = appName;
      WG_IP          = wgIp;
      API_PORT       = apiPort;
      PULL_MODELS    = pullCmds;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "startup.sh";  vars = templateVars; }
          { name = "fallback.sh"; vars = templateVars; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Ollama LLM Server";
      };
    });
  };
}
