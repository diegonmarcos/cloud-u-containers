{
  description = "Container Orchestrator — resource budget management for on-demand services on oci-apps";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "orchestrator";
      api_port = 9100;   # orchestrator HTTP API (localhost only)
    };

    title = "Container Orchestrator";

    # ── Manifest: resource budgets for all services ──────────────────────
    mkManifest = pkgs: pkgs.writeText "manifest.json" (builtins.toJSON {
      vm = {
        total_cpus = 4;
        total_memory_gb = 24;
        safety_threshold = 0.80;  # 80% = 19.2 GB usable
      };
      tiers = {
        always_on = {
          services = {
            crawlee-cloud = { containers = ["crawlee_*"]; est_memory_gb = 1.0; priority = 0; };
            rust-api      = { containers = ["rust-api"];   est_memory_gb = 0.1; priority = 0; };
            kg-graph      = { containers = ["surrealdb"];  est_memory_gb = 0.2; priority = 0; };
            rig           = { containers = ["rig"];        est_memory_gb = 0.1; priority = 0; };
            orchestrator  = { containers = ["orchestrator"]; est_memory_gb = 0.05; priority = 0; };
          };
        };
        on_demand = {
          services = {
            quant-lab-full  = { containers = ["quant_full_*"];  est_memory_gb = 8.0;  priority = 1; };
            quant-lab-light = { containers = ["quant_light_*"]; est_memory_gb = 2.0;  priority = 2; };
            photoprism      = { containers = ["photoprism_*"];  est_memory_gb = 1.5;  priority = 3; };
            nocodb          = { containers = ["nocodb*"];        est_memory_gb = 0.5;  priority = 4; };
            lgtm            = { containers = ["lgtm_*"];        est_memory_gb = 2.0;  priority = 5; };
            code-server     = { containers = ["code-server"];   est_memory_gb = 0.5;  priority = 6; };
            grist           = { containers = ["grist_*"];       est_memory_gb = 0.3;  priority = 7; };
            hedgedoc        = { containers = ["hedgedoc_*"];    est_memory_gb = 0.3;  priority = 8; };
            etherpad        = { containers = ["etherpad_*"];    est_memory_gb = 0.2;  priority = 9; };
            gitea           = { containers = ["gitea"];         est_memory_gb = 0.3;  priority = 10; };
            filebrowser     = { containers = ["filebrowser_*"]; est_memory_gb = 0.1;  priority = 11; };
            revealmd        = { containers = ["revealmd_*"];    est_memory_gb = 0.1;  priority = 12; };
            affine          = { containers = ["affine"];        est_memory_gb = 0.5;  priority = 13; };
          };
        };
      };
    });

    # ── Orchestrator shell script ────────────────────────────────────────
    mkOrchestrator = pkgs: pkgs.writeText "orchestrator.sh" ''
      #!/bin/sh
      # Container Orchestrator — resource budget management
      # Runs as a daemon, exposes HTTP API via socat
      set -e

      MANIFEST="/app/manifest.json"
      STATE_DIR="/app/state"
      LOG="/app/logs/orchestrator.log"
      API_PORT=''${API_PORT:-9100}

      mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

      log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG"; }

      # ── JSON helpers (jq required) ──────────────────────────────────────

      get_threshold() {
        jq -r '.vm.total_memory_gb * .vm.safety_threshold' "$MANIFEST"
      }

      get_always_on_budget() {
        jq -r '[.tiers.always_on.services[].est_memory_gb] | add // 0' "$MANIFEST"
      }

      get_service_budget() {
        local svc="$1"
        jq -r --arg s "$svc" '
          (.tiers.on_demand.services[$s] // .tiers.always_on.services[$s])
          | .est_memory_gb // 0' "$MANIFEST"
      }

      get_service_containers() {
        local svc="$1"
        jq -r --arg s "$svc" '
          (.tiers.on_demand.services[$s] // .tiers.always_on.services[$s])
          | .containers[]' "$MANIFEST"
      }

      get_service_priority() {
        local svc="$1"
        jq -r --arg s "$svc" '
          (.tiers.on_demand.services[$s] // .tiers.always_on.services[$s])
          | .priority // 999' "$MANIFEST"
      }

      list_on_demand_services() {
        jq -r '.tiers.on_demand.services | keys[]' "$MANIFEST"
      }

      # ── Docker helpers ──────────────────────────────────────────────────

      # Get actual memory usage in GB for a container pattern
      get_actual_memory() {
        local pattern="$1"
        docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null \
          | grep -E "^$pattern" \
          | awk '{
              split($2, a, "/")
              val = a[1]
              if (index(val, "GiB") > 0) { gsub("GiB","",val); total += val }
              else if (index(val, "MiB") > 0) { gsub("MiB","",val); total += val/1024 }
              else if (index(val, "KiB") > 0) { gsub("KiB","",val); total += val/1048576 }
            } END { printf "%.3f", total+0 }'
      }

      # Get total actual memory of all running containers
      get_total_actual_memory() {
        docker stats --no-stream --format '{{.MemUsage}}' 2>/dev/null \
          | awk '{
              split($1, a, "/")
              val = a[1]
              if (index(val, "GiB") > 0) { gsub("GiB","",val); total += val }
              else if (index(val, "MiB") > 0) { gsub("MiB","",val); total += val/1024 }
              else if (index(val, "KiB") > 0) { gsub("KiB","",val); total += val/1048576 }
            } END { printf "%.3f", total+0 }'
      }

      # Check if a service has running containers
      is_service_running() {
        local svc="$1"
        for pattern in $(get_service_containers "$svc"); do
          # Handle glob patterns
          case "$pattern" in
            *\**) count=$(docker ps --format '{{.Names}}' | grep -cE "^''${pattern//\*/.*}$" 2>/dev/null || echo 0) ;;
            *)    count=$(docker ps --format '{{.Names}}' | grep -cxF "$pattern" 2>/dev/null || echo 0) ;;
          esac
          [ "$count" -gt 0 ] && return 0
        done
        return 1
      }

      # Start containers for a service (find compose file in /opt/containers/)
      start_service() {
        local svc="$1"
        local compose_dir="/opt/containers/$svc"
        if [ -d "$compose_dir" ] && [ -f "$compose_dir/docker-compose.yml" ]; then
          cd "$compose_dir"
          docker compose $([ -f .secrets ] && echo '--env-file .secrets') up -d
          log "Started service: $svc"
        else
          log "ERROR: No compose file for $svc at $compose_dir"
          return 1
        fi
      }

      # Stop containers for a service
      stop_service() {
        local svc="$1"
        local compose_dir="/opt/containers/$svc"
        if [ -d "$compose_dir" ] && [ -f "$compose_dir/docker-compose.yml" ]; then
          cd "$compose_dir"
          docker compose down
          log "Stopped service: $svc"
        else
          # Fallback: stop individual containers by pattern
          for pattern in $(get_service_containers "$svc"); do
            case "$pattern" in
              *\**) docker ps --format '{{.Names}}' | grep -E "^''${pattern//\*/.*}$" | xargs -r docker stop ;;
              *)    docker stop "$pattern" 2>/dev/null || true ;;
            esac
          done
          log "Stopped service (fallback): $svc"
        fi
      }

      # ── Budget check & eviction ──────────────────────────────────────────

      # Check if we have enough headroom to start a service
      check_budget() {
        local svc="$1"
        local threshold=$(get_threshold)
        local current=$(get_total_actual_memory)
        local needed=$(get_service_budget "$svc")
        local available=$(echo "$threshold - $current" | bc -l)

        log "Budget check: $svc needs ''${needed}GB, available ''${available}GB (current ''${current}GB / threshold ''${threshold}GB)"

        echo "$available $needed" | awk '{ exit ($1 >= $2) ? 0 : 1 }'
      }

      # Evict lowest-priority on-demand services until we have enough headroom
      evict_for() {
        local target_svc="$1"
        local target_budget=$(get_service_budget "$target_svc")
        local target_priority=$(get_service_priority "$target_svc")

        # Get running on-demand services sorted by priority (highest number = lowest priority = evict first)
        local candidates=""
        for svc in $(list_on_demand_services); do
          if is_service_running "$svc"; then
            local pri=$(get_service_priority "$svc")
            # Only evict lower priority (higher number)
            if [ "$pri" -gt "$target_priority" ]; then
              candidates="$candidates $pri:$svc"
            fi
          fi
        done

        # Sort by priority descending (evict lowest priority first)
        for entry in $(echo "$candidates" | tr ' ' '\n' | sort -t: -k1 -rn); do
          local svc="''${entry#*:}"
          log "Evicting $svc (priority $( echo "$entry" | cut -d: -f1 )) to make room for $target_svc"
          stop_service "$svc"
          sleep 2

          # Re-check budget
          if check_budget "$target_svc"; then
            log "Enough headroom after evicting $svc"
            return 0
          fi
        done

        log "WARNING: Could not free enough memory for $target_svc even after evictions"
        return 1
      }

      # ── HTTP API ─────────────────────────────────────────────────────────

      handle_request() {
        local method="$1"
        local path="$2"

        case "$method $path" in
          "GET /status")
            local threshold=$(get_threshold)
            local current=$(get_total_actual_memory)
            local available=$(echo "$threshold - $current" | bc -l)

            # Build service status
            local services_json="{"
            local first=true
            for svc in $(list_on_demand_services); do
              if is_service_running "$svc"; then
                state="running"
              else
                state="stopped"
              fi
              if [ "$first" = true ]; then first=false; else services_json="$services_json,"; fi
              services_json="$services_json\"$svc\":{\"state\":\"$state\",\"budget_gb\":$(get_service_budget "$svc"),\"priority\":$(get_service_priority "$svc")}"
            done
            services_json="$services_json}"

            printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"total_memory_gb":%.1f,"used_memory_gb":%.3f,"available_gb":%.3f,"threshold_gb":%.1f,"services":%s}' \
              "$(jq -r '.vm.total_memory_gb' "$MANIFEST")" "$current" "$available" "$threshold" "$services_json"
            ;;

          "POST /start/"*)
            local svc="''${path#/start/}"
            log "API: start request for $svc"

            if is_service_running "$svc"; then
              printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"status":"already_running","service":"%s"}' "$svc"
              return
            fi

            if check_budget "$svc"; then
              start_service "$svc"
              printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"status":"started","service":"%s"}' "$svc"
            else
              log "Not enough headroom, attempting eviction for $svc"
              if evict_for "$svc"; then
                start_service "$svc"
                printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"status":"started_after_eviction","service":"%s"}' "$svc"
              else
                printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n\r\n{"status":"insufficient_resources","service":"%s"}' "$svc"
              fi
            fi
            ;;

          "POST /stop/"*)
            local svc="''${path#/stop/}"
            log "API: stop request for $svc"
            stop_service "$svc"
            printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"status":"stopped","service":"%s"}' "$svc"
            ;;

          "GET /health")
            printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"status":"ok"}'
            ;;

          *)
            printf 'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"error":"not_found","endpoints":["/status","/start/<svc>","/stop/<svc>","/health"]}'
            ;;
        esac
      }

      # ── Background monitor (OOM guard) ──────────────────────────────────

      monitor_loop() {
        while true; do
          sleep 30

          local threshold=$(get_threshold)
          local current=$(get_total_actual_memory)
          local pct=$(echo "scale=1; $current / $(jq -r '.vm.total_memory_gb' "$MANIFEST") * 100" | bc -l 2>/dev/null || echo "0")

          # Emergency: if over 90% of total RAM, stop lowest-priority on-demand
          local emergency_threshold=$(echo "$(jq -r '.vm.total_memory_gb' "$MANIFEST") * 0.90" | bc -l)
          if echo "$current $emergency_threshold" | awk '{ exit ($1 > $2) ? 0 : 1 }'; then
            log "EMERGENCY: Memory at ''${current}GB / ''${pct}%% — evicting lowest-priority service"
            # Find lowest-priority running on-demand service
            local worst_pri=0
            local worst_svc=""
            for svc in $(list_on_demand_services); do
              if is_service_running "$svc"; then
                local pri=$(get_service_priority "$svc")
                if [ "$pri" -gt "$worst_pri" ]; then
                  worst_pri=$pri
                  worst_svc=$svc
                fi
              fi
            done
            if [ -n "$worst_svc" ]; then
              log "Emergency stopping: $worst_svc (priority $worst_pri)"
              stop_service "$worst_svc"
            fi
          fi

          # Log status every 5 minutes (every 10 iterations)
          if [ -f "$STATE_DIR/tick" ]; then
            tick=$(cat "$STATE_DIR/tick")
          else
            tick=0
          fi
          tick=$((tick + 1))
          echo "$tick" > "$STATE_DIR/tick"
          if [ $((tick % 10)) -eq 0 ]; then
            log "Status: memory ''${current}GB / ''${pct}%% of total"
          fi
        done
      }

      # ── Main ─────────────────────────────────────────────────────────────

      log "Orchestrator starting (API port $API_PORT)"
      log "Manifest: $(jq -r '.vm.total_memory_gb' "$MANIFEST")GB total, threshold $(get_threshold)GB"

      # Start background monitor
      monitor_loop &
      MONITOR_PID=$!

      # Start HTTP API server (socat)
      log "HTTP API listening on 0.0.0.0:$API_PORT"
      while true; do
        socat TCP-LISTEN:$API_PORT,reuseaddr,fork EXEC:"/app/api-handler.sh" 2>/dev/null || {
          log "socat exited, restarting in 5s..."
          sleep 5
        }
      done
    '';

    # ── API handler (called by socat for each connection) ────────────────
    mkApiHandler = pkgs: pkgs.writeText "api-handler.sh" ''
      #!/bin/sh
      # Read HTTP request
      read -r method path _version
      method=$(echo "$method" | tr -d '\r')
      path=$(echo "$path" | tr -d '\r')

      # Skip headers
      while read -r header; do
        header=$(echo "$header" | tr -d '\r')
        [ -z "$header" ] && break
      done

      # Source the handler functions
      . /app/orchestrator-lib.sh

      # Handle request
      handle_request "$method" "$path"
    '';

    # ── Docker Compose ───────────────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        orchestrator:
          image: alpine:latest
          container_name: ${config.container_name}
          restart: unless-stopped
          entrypoint: ["/bin/sh", "/app/orchestrator.sh"]
          ports:
            - "127.0.0.1:${toString config.api_port}:${toString config.api_port}"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - ./orchestrator.sh:/app/orchestrator.sh:ro
            - ./api-handler.sh:/app/api-handler.sh:ro
            - ./orchestrator-lib.sh:/app/orchestrator-lib.sh:ro
            - ./manifest.json:/app/manifest.json:ro
            - orchestrator_state:/app/state
            - orchestrator_logs:/app/logs
          environment:
            - API_PORT=${toString config.api_port}
          deploy:
            resources:
              limits:
                memory: 64M
              reservations:
                memory: 32M
          healthcheck:
            test: ["CMD", "wget", "-q", "--spider", "http://localhost:${toString config.api_port}/health"]
            interval: 30s
            timeout: 5s
            retries: 3
            start_period: 15s
          networks:
            - dev_network

      volumes:
        orchestrator_state:
        orchestrator_logs:

      networks:
        dev_network:
          external: true
          name: dev_network
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "orchestrator-configs" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkManifest pkgs} $out/manifest.json

        # Build the orchestrator script (extract handle_request as lib for socat)
        cp ${mkOrchestrator pkgs} $out/orchestrator.sh
        chmod +x $out/orchestrator.sh

        cp ${mkApiHandler pkgs} $out/api-handler.sh
        chmod +x $out/api-handler.sh

        # Extract handle_request and helpers as a library for the API handler
        # (socat forks a new process per connection, needs the functions)
        sed -n '/^      get_threshold/,/^      # ── Main/p' ${mkOrchestrator pkgs} \
          | head -n -2 > $out/orchestrator-lib.sh
        chmod +x $out/orchestrator-lib.sh

        # Validate manifest JSON
        jq '.' $out/manifest.json > /dev/null
      '';
    });
  };
}
