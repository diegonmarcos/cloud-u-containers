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
    docker = import ../../_shared/docker.nix;

    # GHCR image for forwarder: bake forwarder.sh into image
    ghcrForwarder = docker.mkGhcrBuild {
      name = "sauron-forwarder";
      fromImage = "debian:bookworm-slim";
      configFiles = [
        { src = "forwarder.sh"; dst = "/forwarder.sh"; }
      ];
    };

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

    mkForwarderSh = pkgs: pkgs.writeText "forwarder.sh" ''
      #!/bin/sh
      apt-get update && apt-get install -y --no-install-recommends netcat-openbsd && rm -rf /var/lib/apt/lists/*
      echo "Forwarding alerts to $CENTRAL_HOST:$CENTRAL_PORT"
      tail -F /var/log/sauron/alerts.jsonl 2>/dev/null | while read line; do
        echo "$line" | nc -w1 $CENTRAL_HOST $CENTRAL_PORT 2>/dev/null || true
      done
    '';

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_sauron-lite/src/flake.nix";
      volumes = {
        sauron_logs = {};
        sauron_queue = {};
      };
      services = {
        sauron = docker.mkService {
          name = "sauron";
          image = "ghcr.io/diegonmarcos/sauron:latest";
          build = ".";
          container_name = config.container_name;
          restart = "no";
          skipReadOnly = true;
          volumes = [
            "/etc:/watch/etc:ro"
            "/home:/watch/home:ro"
            "sauron_logs:/var/log/sauron"
            "sauron_queue:/var/spool/sauron"
          ];
          environment = {
            TZ = config.timezone;
            VM_NAME = "\${VM_NAME:-unknown}";
            WATCH_DIRS = "/watch/etc /watch/home";
            QUEUE_FILE = "/var/spool/sauron/scan-queue.txt";
            ALERTS_FILE = "/var/log/sauron/alerts.jsonl";
            RULES_DIR = "/etc/sauron/yara-rules";
          };
          memLimit = config.mem_limit;
          cpuLimit = config.cpu_limit;
          healthcheck = {
            test = ''["CMD", "pgrep", "-f", "inotifywait"]'';
            interval = "60s";
            timeout = "5s";
            retries = 3;
          };
        };
        forwarder = docker.mkService {
          name = "forwarder";
          image = ghcrForwarder.image;
          build = ghcrForwarder.build;
          container_name = "sauron-forwarder";
          restart = "no";
          skipReadOnly = true;
          entrypoint = ["/bin/sh" "/forwarder.sh"];
          volumes = [
            "sauron_logs:/var/log/sauron:ro"
          ];
          environment = {
            CENTRAL_HOST = config.central_host;
            CENTRAL_PORT = "\"${toString config.central_port}\"";
          };
          depends_on = { sauron = {}; };
          memLimit = "16m";
          cpuLimit = "0.05";
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "sauron-lite-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkForwarderSh pkgs} $out/forwarder.sh
        chmod +x $out/forwarder.sh
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
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; docsPath = ./docs; };
    });
  };
}
