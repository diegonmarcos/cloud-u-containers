{
  description = "Ollama LLM Server (ARM CPU) — qwen2.5:1.5b + nomic-embed-text for hai agent and octocode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "ollama-hai";
      image = "ollama/ollama:latest";
      api_port = 11435;
      wg_ip = "10.0.0.6";
      timezone = "America/Chicago";
      keep_alive = "10m";
      models = [
        "qwen2.5:1.5b"
        "nomic-embed-text"
      ];
    };

    title = "Ollama HAI (ARM CPU — qwen2.5:1.5b + nomic-embed-text)";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY             ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!                  ║
      # ╠══════════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ad-agi_ollama-hai/src/flake.nix    ║
      # ║ Rebuild: build.sh ship                                              ║
      # ╚══════════════════════════════════════════════════════════════════════╝
      services:
        ollama-hai:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          network_mode: host
          volumes:
            - ollama_hai_data:/root/.ollama
          environment:
            - TZ=${config.timezone}
            - OLLAMA_KEEP_ALIVE=${config.keep_alive}
            - OLLAMA_HOST=0.0.0.0:${toString config.api_port}
            - OLLAMA_NUM_PARALLEL=2
            - OLLAMA_MAX_LOADED_MODELS=2
          deploy:
            resources:
              limits:
                memory: 6G
          healthcheck:
            test: ["CMD", "curl", "-sf", "http://localhost:${toString config.api_port}/api/tags"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 30s

      volumes:
        ollama_hai_data:
    '';

    mkStartup = pkgs: pkgs.writeText "startup.sh" ''
      #!/bin/sh
      set -e
      echo "=== Ollama HAI Startup ==="
      echo "Waiting for Ollama API to be ready..."

      for i in $(seq 1 60); do
        if curl -sf http://localhost:${toString config.api_port}/api/tags >/dev/null 2>&1; then
          echo "Ollama API ready."
          break
        fi
        sleep 1
      done

      echo "Pulling models (Q4, CPU-optimized)..."
      ${builtins.concatStringsSep "\n      " (map (m: ''
      echo "  Pulling ${m}..."
      docker exec ${config.container_name} ollama pull ${m}'') config.models)}

      echo ""
      echo "=== Startup complete ==="
      echo "API available at: http://${config.wg_ip}:${toString config.api_port}"
      echo "Test: curl http://${config.wg_ip}:${toString config.api_port}/api/tags"
      echo "Embeddings: curl http://${config.wg_ip}:${toString config.api_port}/v1/embeddings -d '{\"model\":\"nomic-embed-text\",\"input\":\"test\"}'"
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "ollama-hai-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkStartup pkgs} $out/startup.sh
        chmod +x $out/startup.sh
      '';
    in {
      default = defaultPkg;
    });
  };
}
