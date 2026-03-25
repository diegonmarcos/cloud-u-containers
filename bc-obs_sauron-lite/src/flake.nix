{
  description = "Sauron Lite - Lightweight file integrity and malware scanner";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "sauron";
      timezone = "Europe/Madrid";

      # Central server for alerts
      central_host = "35.226.147.64";
      central_port = 5514;

      # Resource limits (for 1GB VMs)
      mem_limit = "64m";
      cpu_limit = "0.25";
    };

    title = "Sauron Lite - Lightweight file integrity and malware scanner";

    # Dockerfile for the scanner
    mkDockerfile = pkgs: pkgs.writeText "Dockerfile" ''
      FROM debian:bookworm-slim

      RUN apt-get update && apt-get install -y --no-install-recommends \
          inotify-tools \
          yara \
          bash \
          coreutils \
          findutils \
          procps \
          && rm -rf /var/lib/apt/lists/*

      WORKDIR /app

      COPY sauron.sh /app/sauron.sh
      RUN chmod +x /app/sauron.sh

      CMD ["/app/sauron.sh"]
    '';

    # Main scanner script
    mkSauronSh = pkgs: pkgs.writeText "sauron.sh" ''
      #!/bin/bash
      set -e

      WATCH_DIRS="''${WATCH_DIRS:-/watch/etc /watch/home}"
      QUEUE_FILE="''${QUEUE_FILE:-/var/spool/sauron/scan-queue.txt}"
      ALERTS_FILE="''${ALERTS_FILE:-/var/log/sauron/alerts.jsonl}"
      RULES_DIR="''${RULES_DIR:-/etc/sauron/yara-rules}"
      VM_NAME="''${VM_NAME:-unknown}"

      mkdir -p "$(dirname "$QUEUE_FILE")" "$(dirname "$ALERTS_FILE")"
      touch "$QUEUE_FILE" "$ALERTS_FILE"

      log() {
          echo "[$(date -Iseconds)] $1"
      }

      alert() {
          local file="$1"
          local rule="$2"
          local json="{\"timestamp\":\"$(date -Iseconds)\",\"vm\":\"$VM_NAME\",\"file\":\"$file\",\"rule\":\"$rule\"}"
          echo "$json" >> "$ALERTS_FILE"
          log "ALERT: $file matched $rule"
      }

      scan_file() {
          local file="$1"
          if [ -f "$file" ] && [ -d "$RULES_DIR" ]; then
              result=$(yara -r "$RULES_DIR" "$file" 2>/dev/null || true)
              if [ -n "$result" ]; then
                  rule=$(echo "$result" | awk '{print $1}')
                  alert "$file" "$rule"
              fi
          fi
      }

      process_queue() {
          while true; do
              if [ -s "$QUEUE_FILE" ]; then
                  file=$(head -1 "$QUEUE_FILE")
                  sed -i '1d' "$QUEUE_FILE"
                  scan_file "$file"
              else
                  sleep 1
              fi
          done
      }

      # Start queue processor in background
      process_queue &

      log "Sauron starting on $VM_NAME"
      log "Watching: $WATCH_DIRS"

      # Watch for file changes
      inotifywait -m -r -e create -e modify -e moved_to $WATCH_DIRS 2>/dev/null | \
      while read dir event file; do
          filepath="$dir$file"
          echo "$filepath" >> "$QUEUE_FILE"
      done
    '';

    # Basic YARA rules
    mkYaraRules = pkgs: pkgs.writeText "basic.yar" ''
      rule SuspiciousScript {
          meta:
              description = "Detects suspicious script patterns"
              severity = "medium"
          strings:
              $s1 = "curl" ascii
              $s2 = "wget" ascii
              $s3 = "base64" ascii
              $s4 = "/dev/tcp" ascii
              $s5 = "nc -e" ascii
          condition:
              3 of them
      }

      rule CryptoMiner {
          meta:
              description = "Detects cryptocurrency mining indicators"
              severity = "high"
          strings:
              $s1 = "stratum+tcp" ascii
              $s2 = "xmrig" ascii nocase
              $s3 = "minerd" ascii
              $s4 = "cpuminer" ascii
          condition:
              any of them
      }

      rule WebShell {
          meta:
              description = "Detects common webshell patterns"
              severity = "critical"
          strings:
              $s1 = "eval($_" ascii
              $s2 = "base64_decode($_" ascii
              $s3 = "shell_exec(" ascii
              $s4 = "passthru(" ascii
              $s5 = "system($_" ascii
          condition:
              any of them
      }
    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_sauron-lite/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_sauron-lite/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝

      services:
        sauron:
          build: .
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            # Watch paths (read-only)
            - /etc:/watch/etc:ro
            - /home:/watch/home:ro
            # YARA rules
            - ./yara-rules:/etc/sauron/yara-rules:ro
            # Persistent logs and queue
            - ./data/logs:/var/log/sauron
            - ./data/queue:/var/spool/sauron
          environment:
            TZ: ${config.timezone}
            VM_NAME: "''${VM_NAME:-unknown}"
            WATCH_DIRS: /watch/etc /watch/home
            QUEUE_FILE: /var/spool/sauron/scan-queue.txt
            ALERTS_FILE: /var/log/sauron/alerts.jsonl
            RULES_DIR: /etc/sauron/yara-rules
          mem_limit: ${config.mem_limit}
          cpus: ${config.cpu_limit}
          cpu_shares: 256
          logging:
            driver: "json-file"
            options:
              max-size: "5m"
              max-file: "2"
          healthcheck:
            test: ["CMD", "pgrep", "-f", "inotifywait"]
            interval: 60s
            timeout: 5s
            retries: 3

        forwarder:
          image: debian:bookworm-slim
          container_name: sauron-forwarder
          restart: "no"  # container-init handles startup
          network_mode: host
          entrypoint: ["/bin/sh", "-c"]
          command:
            - |
              apt-get update && apt-get install -y --no-install-recommends netcat-openbsd && rm -rf /var/lib/apt/lists/*
              echo "Forwarding alerts to $${CENTRAL_HOST}:$${CENTRAL_PORT}"
              tail -F /var/log/sauron/alerts.jsonl 2>/dev/null | while read line; do
                echo "$$line" | nc -w1 $${CENTRAL_HOST} $${CENTRAL_PORT} 2>/dev/null || true
              done
          volumes:
            - ./data/logs:/var/log/sauron:ro
          environment:
            CENTRAL_HOST: ${config.central_host}
            CENTRAL_PORT: "${toString config.central_port}"
          depends_on:
            - sauron
          mem_limit: 16m
          cpus: "0.05"
    '';

    # .env template
    mkEnvTemplate = pkgs: pkgs.writeText "env.template" ''
      # VM name for identification in alerts
      VM_NAME=oci-f-micro_1

      # Central sauron server (for alert forwarding)
      CENTRAL_HOST=${config.central_host}
      CENTRAL_PORT=${toString config.central_port}
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
      defaultPkg = pkgs.runCommand "sauron-lite-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        mkdir -p $out/yara-rules/custom
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./entrypoint.sh} $out/entrypoint.sh
        cp ${./watcher.sh} $out/watcher.sh
        cp ${./scanner.sh} $out/scanner.sh
        cp ${./yara-rules/custom/cryptominers.yar} $out/yara-rules/custom/cryptominers.yar
        cp ${./yara-rules/custom/suspicious.yar} $out/yara-rules/custom/suspicious.yar
        cp ${./yara-rules/custom/webshells.yar} $out/yara-rules/custom/webshells.yar
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
