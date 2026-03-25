{
  description = "Rig Agentic AI (HAI) — Lightweight Qwen 1.5B Q4 agent with strict guardrails";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "rig-agentic-hai";
      port = 8091;
      ollama_url = "http://localhost:11435";
      ollama_model = "qwen2.5:1.5b";
      c3_mcp_url = "http://c3-services-mcp.app:3101";
      mattermost_url = "http://mattermost.app:8065";
    };

    # Strict allowlist — hai can ONLY use these tools
    allowed_tools = builtins.concatStringsSep "," [
      # Mattermost (via c3-services-mcp proxy)
      "mm_post" "mm_reply" "mm_read" "mm_channels"
      # Email (via mail-mcp proxy)
      "mail_send" "mail_reply"
      # Notifications
      "ntfy_publish"
      # Service registry (read-only)
      "services_list" "services_info"
      # Infra knowledge (via code-graph-context proxy)
      "c3_topology" "c3_configs" "c3_deps"
      "c3_topology_md" "c3_configs_md"
      "c3_deps_front" "cloud_context"
      "knowledge_vm_info" "knowledge_services_by_category"
      # Octocode (via code-graph-context proxy)
      "octocode_search" "octocode_memory"
      # Dagu + GHA (future tools)
      "dagu_trigger" "dagu_list"
      "gha_trigger" "gha_list_runs"
    ];

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
          image: rig-agentic-hai:latest
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            - RIG_PORT=${toString config.port}
            - OLLAMA_URL=${config.ollama_url}
            - OLLAMA_API_BASE_URL=${config.ollama_url}
            - OLLAMA_MODEL=${config.ollama_model}
            - C3_MCP_URL=${config.c3_mcp_url}
            - MATTERMOST_URL=${config.mattermost_url}
            - GUARDRAIL_MAX_TURNS=5
            - GUARDRAIL_DENIED_TOOLS=
            - GUARDRAIL_ALLOWED_TOOLS=${allowed_tools}
            - SELF_HEALING_ENABLED=false
            - MM_BOT_MENTION=@hai-1.5bq4-ai
            - RUST_LOG=rig_agentic=info
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
