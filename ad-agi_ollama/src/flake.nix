{
  description = "Ollama LLM Server - Docker Compose configuration with GPU support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;

    # Configuration options (non-secret)
    config = {
      container_name = "ollama";
      image = "ollama/ollama:latest";
      api_port = 11434;
      wg_ip = svc.ollama.ip;
      timezone = "America/Chicago";
      keep_alive = "5m";
      kv_cache_type = "q4_0";
      models = [
        "deepseek-r1:14b-qwen-distill-q8_0"
        "MFDoom/deepseek-r1-tool-calling:14b-qwen-distill-q8_0"
        "qwen2.5:14b-instruct-q8_0"
      ];
    };

    title = "Ollama LLM Server";

    # Generate docker-compose.yml
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ad-agi_ollama/src/flake.nix     ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ad-agi_ollama/build.sh ship    ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        ollama:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
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

      echo "Pulling Q8 models..."
      ${builtins.concatStringsSep "\n      " (map (m: ''
      echo "  Pulling ${m}..."
      docker exec ${config.container_name} ollama pull ${m}'') config.models)}

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


    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) concatMapStrings hasSuffix optionalString filter subtractLists removeSuffix;
      inherit (builtins) attrNames readDir pathExists;

      portKeys = filter (k: hasSuffix "_port" k || k == "port") (attrNames config);
      imageKeys = filter (k: hasSuffix "_image" k || k == "image") (attrNames config);
      containerKeys = filter (k: hasSuffix "_container" k || k == "container_name") (attrNames config);
      domainKeys = filter (k: k == "domain" || k == "base_domain") (attrNames config);
      otherKeys = subtractLists (portKeys ++ imageKeys ++ containerKeys ++ domainKeys) (attrNames config);

      row = k: let
        v = config.${k};
        vs = if builtins.isBool v then (if v then "true" else "false")
             else if builtins.isAttrs v || builtins.isList v then builtins.toJSON v
             else toString v;
      in "| `${k}` | `${vs}` |\n";
      section = heading: keys: optionalString (keys != []) ''
        ## ${heading}
        | Key | Value |
        |-----|-------|
        ${concatMapStrings row keys}
      '';

      hasNarrative = pathExists ./docs;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir ./docs))
        else [];

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
      '';

      summaryMd = pkgs.writeText "SUMMARY.md" ''
        # Summary
        - [Specification](./spec.md)
        - [Generated Configs](./configs.md)
        ${concatMapStrings (f: "- [${removeSuffix ".md" f}](./${f})\n") narrativeFiles}
      '';

      bookToml = pkgs.writeText "book.toml" ''
        [book]
        title = "${title}"
        [output.html]
        default-theme = "ayu"
      '';
    in pkgs.runCommand "docs" {
      nativeBuildInputs = [ pkgs.mdbook pkgs.file ];
    } ''
      mkdir -p build/src
      cp ${bookToml} build/book.toml
      cp ${summaryMd} build/src/SUMMARY.md
      cp ${specMd} build/src/spec.md
      ${optionalString hasNarrative "cp ${./docs}/*.md build/src/ 2>/dev/null || true"}

      # Generate configs.md from packages.default output
      echo "# Generated Configuration Files" > build/src/configs.md
      echo "" >> build/src/configs.md
      echo 'These files are produced by nix build and deployed to the VM.' >> build/src/configs.md
      echo "" >> build/src/configs.md
      find ${defaultPkg} -type f | sort | while read -r f; do
        relpath="''${f#${defaultPkg}/}"
        case "$relpath" in
          .secrets|*.secrets|*.lock|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.eot) continue ;;
        esac
        case "$relpath" in
          *.yml|*.yaml)   lang="yaml" ;;
          *.json)         lang="json" ;;
          *.toml)         lang="toml" ;;
          *.py)           lang="python" ;;
          *.sh)           lang="bash" ;;
          *.js|*.ts)      lang="javascript" ;;
          *.tf)           lang="hcl" ;;
          *.conf|*.cnf)   lang="ini" ;;
          *.html)         lang="html" ;;
          *.sql)          lang="sql" ;;
          *.zone)         lang="dns" ;;
          Dockerfile*)    lang="dockerfile" ;;
          Caddyfile*)     lang="caddy" ;;
          *)              lang="" ;;
        esac
        if file -b --mime-type "$f" | grep -q "^text/"; then
          echo '## '"$relpath" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo "~~~$lang" >> build/src/configs.md
          cat "$f" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo '~~~' >> build/src/configs.md
          echo "" >> build/src/configs.md
        fi
      done

      cd build && mdbook build -d $out
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "ollama-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkStartup pkgs} $out/startup.sh
        cp ${mkFallback pkgs} $out/fallback.sh
        chmod +x $out/startup.sh $out/fallback.sh
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
