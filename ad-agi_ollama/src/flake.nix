{
  description = "Ollama LLM Server - Docker Compose configuration with GPU support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # Configuration options (non-secret)
    config = {
      container_name = "ollama";
      image = "ollama/ollama:latest";
      api_port = 11434;
      wg_ip = "10.0.0.8";
      timezone = "America/Chicago";
      keep_alive = "5m";
      kv_cache_type = "q4_0";
      models = [
        "deepseek-r1:14b"
        "qwen2.5:14b"
      ];
      models_q8 = [
        "deepseek-r1:14b-q8_0"
        "qwen2.5:14b-q8_0"
      ];
    };

    # Generate docker-compose.yml
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        ollama:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${config.wg_ip}:${toString config.api_port}:11434"
          volumes:
            - ollama_data:/root/.ollama
          environment:
            - TZ=${config.timezone}
            - OLLAMA_KEEP_ALIVE=${config.keep_alive}
            - OLLAMA_KV_CACHE_TYPE=${config.kv_cache_type}
            - NVIDIA_VISIBLE_DEVICES=all
          deploy:
            resources:
              reservations:
                devices:
                  - driver: nvidia
                    count: 1
                    capabilities: [gpu]

      volumes:
        ollama_data:
    '';

    # Startup script: pull models on first boot
    mkStartup = pkgs: pkgs.writeText "startup.sh" ''
      #!/bin/sh
      set -e
      echo "=== Ollama Startup ==="
      echo "Waiting for Ollama API to be ready..."

      # Wait for ollama to start (up to 60s)
      for i in $(seq 1 60); do
        if docker exec ${config.container_name} ollama list >/dev/null 2>&1; then
          echo "Ollama API ready."
          break
        fi
        sleep 1
      done

      echo "Pulling default models (Q4)..."
      ${builtins.concatStringsSep "\n      " (map (m: ''
      echo "  Pulling ${m}..."
      docker exec ${config.container_name} ollama pull ${m}'') config.models)}

      echo ""
      echo "Default models pulled. To pull Q8 variants (higher quality, ~14GB VRAM each):"
      ${builtins.concatStringsSep "\n      " (map (m: ''
      echo "  docker exec ${config.container_name} ollama pull ${m}"'') config.models_q8)}

      echo ""
      echo "=== Startup complete ==="
      echo "API available at: http://${config.wg_ip}:${toString config.api_port}"
      echo "Test: curl http://${config.wg_ip}:${toString config.api_port}/api/tags"
    '';

    # Fallback script: switch to Vast.ai if GCP spot unavailable
    mkFallback = pkgs: pkgs.writeText "fallback.sh" ''
      #!/bin/sh
      set -e
      echo "=== Ollama Fallback Check ==="

      GCP_WG_IP="${config.wg_ip}"
      API_PORT="${toString config.api_port}"
      VASTAI_API_KEY="''${VASTAI_API_KEY:-}"

      # Check if GCP spot VM is alive via WireGuard
      echo "Checking GCP spot VM at $GCP_WG_IP..."
      if curl -sf --connect-timeout 5 "http://$GCP_WG_IP:$API_PORT/api/tags" >/dev/null 2>&1; then
        echo "GCP spot VM is alive and Ollama is responding."
        echo "No fallback needed."
        exit 0
      fi

      echo "GCP spot VM is DOWN or unreachable."
      echo ""

      if [ -z "$VASTAI_API_KEY" ]; then
        echo "ERROR: VASTAI_API_KEY not set. Cannot provision fallback."
        echo "Set it via: export VASTAI_API_KEY=<key>"
        echo "Or add to secrets.yaml and run: source <(sops -d secrets.yaml)"
        exit 1
      fi

      echo "Searching Vast.ai for available GPU instances..."
      echo ""
      echo "To provision manually:"
      echo "  1. Visit https://cloud.vast.ai/search"
      echo "  2. Search for RTX A4000 or T4 (16GB VRAM)"
      echo "  3. Select cheapest spot/on-demand instance"
      echo "  4. Deploy with: vastai create instance <id> --image ollama/ollama --disk 50"
      echo "  5. SSH in and run startup.sh to pull models"
      echo ""
      echo "To provision via CLI (requires vastai pip package):"
      echo "  vastai search offers 'gpu_ram>=16 num_gpus=1 dph<0.30 inet_down>200' -o dph"
      echo "  vastai create instance <OFFER_ID> --image ollama/ollama:latest --disk 50"
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "ollama-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkStartup pkgs} $out/startup.sh
        cp ${mkFallback pkgs} $out/fallback.sh
        chmod +x $out/startup.sh $out/fallback.sh
      '';
    });
  };
}
