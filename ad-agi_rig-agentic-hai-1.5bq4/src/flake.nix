{
  description = "Rig Agentic AI (HAI) — Lightweight Qwen 1.5B Q4 agent with strict guardrails";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-rig-agentic-hai.json (symlink → 2_configs/dist/
    # build-rig-agentic-hai.json). Engine resolves symlink before nix build.
    buildRig = builtins.fromJSON (builtins.readFile ./build-rig-agentic-hai.json);
    svc = buildRig.services;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    # Ollama upstream: look up by declared service name in build.json
    ollamaSvc = svc.${buildJson.rig.ollama_service};
    ollamaUrl = "http://localhost:${toString ollamaSvc.ports.app}";

    config = {
      container_name = buildRig.container.container_name;
      image = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
      port = ports.valueOf "app";
      rig_host = svc.${buildJson.name}.ip;
      ollama_url = ollamaUrl;
      ollama_model = buildJson.rig.ollama_model;
      c3_mcp_url = buildJson.rig.c3_mcp_url;
      mattermost_url = buildJson.rig.mattermost_url;
      mm_bot_mention = buildJson.rig.mm_bot_mention;
      guardrail_max_turns = toString buildJson.rig.guardrail_max_turns;
      self_healing_enabled = if buildJson.rig.self_healing_enabled then "true" else "false";
      rust_log = buildJson.rig.rust_log;
    };

    # Strict allowlist — hai can ONLY use these tools (declared in build.json)
    allowed_tools = builtins.concatStringsSep "," buildJson.rig.allowed_tools;

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔═══════════════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY                  ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!                       ║
      # ╠═══════════════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ad-agi_rig-agentic-hai-1.5bq4/         ║
      # ║ Rebuild: build.sh ship                                                   ║
      # ╚═══════════════════════════════════════════════════════════════════════════╝
      services:
        rig-agentic-hai:
          build:
            context: .
            dockerfile: Dockerfile
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            - RIG_HOST=${config.rig_host}
            - RIG_PORT=${toString config.port}
            - OLLAMA_URL=${config.ollama_url}
            - OLLAMA_API_BASE_URL=${config.ollama_url}
            - OLLAMA_MODEL=${config.ollama_model}
            - C3_MCP_URL=${config.c3_mcp_url}
            - MATTERMOST_URL=${config.mattermost_url}
            - GUARDRAIL_MAX_TURNS=${config.guardrail_max_turns}
            - GUARDRAIL_DENIED_TOOLS=
            - GUARDRAIL_ALLOWED_TOOLS=${allowed_tools}
            - SELF_HEALING_ENABLED=${config.self_healing_enabled}
            - MM_BOT_MENTION=${config.mm_bot_mention}
            - RUST_LOG=${config.rust_log}
          healthcheck:
            test: ["CMD", "curl", "-sf", "http://localhost:${toString config.port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "rig-agentic-hai-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
