{
  description = "Ollama LLM Server - ARM CPU configuration (7b models)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;

    config = {
      container_name = "ollama-arm";
      image = "ollama/ollama:latest";
      api_port = 11434;
      wg_ip = svc."ollama-arm".ip;
      timezone = "America/Chicago";
      keep_alive = "10m";
      models = [
        "deepseek-r1:7b"
        "qwen2.5:7b"
      ];
    };

    title = "Ollama LLM Server (ARM CPU)";
    docker = import ../../_shared/docker.nix;

    ghcr-ollama-arm = docker.mkGhcrBuild {
      name = "ollama-arm";
      fromImage = config.image;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ad-agi_ollama-arm/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ad-agi_ollama-arm/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        ollama:
          image: ${ghcr-ollama-arm.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - ollama_data:/root/.ollama
          environment:
            - TZ=${config.timezone}
            - OLLAMA_KEEP_ALIVE=${config.keep_alive}
            - OLLAMA_HOST=0.0.0.0
            - OLLAMA_NUM_PARALLEL=2
            - OLLAMA_MAX_LOADED_MODELS=1
          deploy:
            resources:
              limits:
                memory: 16G

      volumes:
        ollama_data:
    '';

    mkStartup = pkgs: pkgs.writeText "startup.sh" ''
      #!/bin/sh
      set -e
      echo "=== Ollama ARM Startup ==="
      echo "Waiting for Ollama API to be ready..."

      for i in $(seq 1 60); do
        if docker exec ${config.container_name} ollama list >/dev/null 2>&1; then
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
      defaultPkg = pkgs.runCommand "ollama-arm-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkStartup pkgs} $out/startup.sh
        chmod +x $out/startup.sh
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
