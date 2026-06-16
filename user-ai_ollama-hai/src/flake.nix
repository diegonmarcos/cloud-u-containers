{
  description = "Ollama HAI (ARM CPU — qwen2.5:1.5b + nomic-embed-text) — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-ollama-hai.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    svc     = container.services;
    wgIp    = svc.${buildJson.name}.ip;
    apiPort = toString buildJson.ports.app;
    cname   = buildJson.containers.app.container_name;

    # Build the pull-commands block inline so startup.sh.tpl stays simple.
    pullCommands = lib.concatMapStringsSep "\n" (m: ''
      echo "  Pulling ${m}..."
      docker exec ${cname} ollama pull ${m}'') buildJson.ollama.models;

    startupVars = {
      API_PORT      = apiPort;
      WG_IP         = wgIp;
      PULL_COMMANDS = pullCommands;
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
        title = "Ollama HAI (ARM CPU — qwen2.5:1.5b + nomic-embed-text)";
      };
    });
  };
}
