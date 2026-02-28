#!/bin/sh
MANIFEST="/app/manifest.json"
STATE_DIR="/app/state"
LOG="/app/logs/orchestrator.log"
API_PORT=${API_PORT:-9100}

mkdir -p "$STATE_DIR" /app/logs 2>/dev/null

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

get_threshold() { jq -r '.vm.total_memory_gb * .vm.safety_threshold' "$MANIFEST"; }

get_service_budget() { jq -r --arg s "$1" '(.tiers.on_demand.services[$s] // .tiers.always_on.services[$s]) | .est_memory_gb // 0' "$MANIFEST"; }

get_service_priority() { jq -r --arg s "$1" '(.tiers.on_demand.services[$s] // .tiers.always_on.services[$s]) | .priority // 999' "$MANIFEST"; }

get_service_containers() { jq -r --arg s "$1" '(.tiers.on_demand.services[$s] // .tiers.always_on.services[$s]) | .containers[]' "$MANIFEST"; }

list_on_demand_services() { jq -r '.tiers.on_demand.services | keys[]' "$MANIFEST"; }

get_total_actual_memory() {
  docker stats --no-stream --format '{{.MemUsage}}' 2>/dev/null | awk '{
    val=$1; gsub(/[A-Za-z]/,"",val)
    if($1~/GiB/) t+=val; else if($1~/MiB/) t+=val/1024; else if($1~/KiB/) t+=val/1048576
  } END{printf "%.3f",t+0}'
}

is_service_running() {
  for p in $(get_service_containers "$1"); do
    case "$p" in *\**) docker ps --format '{{.Names}}' | grep -qE "^${p//\*/.*}$" && return 0 ;; *) docker ps --format '{{.Names}}' | grep -qxF "$p" && return 0 ;; esac
  done
  return 1
}

start_service() {
  local d="/opt/containers/$1"
  [ -f "$d/docker-compose.yml" ] && { cd "$d"; docker compose $([ -f .secrets ] && echo '--env-file .secrets') up -d; log "Started: $1"; return 0; }
  log "ERROR: no compose for $1"; return 1
}

stop_service() {
  local d="/opt/containers/$1"
  [ -f "$d/docker-compose.yml" ] && { cd "$d"; docker compose down; log "Stopped: $1"; return 0; }
  for p in $(get_service_containers "$1"); do docker stop "$p" 2>/dev/null; done
  log "Stopped(fallback): $1"
}

check_budget() {
  local threshold=$(get_threshold) current=$(get_total_actual_memory) needed=$(get_service_budget "$1")
  local available=$(echo "$threshold - $current" | bc -l)
  log "Budget: $1 needs ${needed}GB, avail ${available}GB (used ${current}GB / limit ${threshold}GB)"
  echo "$available $needed" | awk '{exit ($1>=$2)?0:1}'
}

evict_for() {
  local tp=$(get_service_priority "$1") candidates=""
  for svc in $(list_on_demand_services); do
    is_service_running "$svc" || continue
    local p=$(get_service_priority "$svc")
    [ "$p" -gt "$tp" ] && candidates="$candidates $p:$svc"
  done
  for entry in $(echo "$candidates" | tr ' ' '\n' | sort -t: -k1 -rn); do
    local svc="${entry#*:}"
    log "Evicting $svc for $1"; stop_service "$svc"; sleep 2
    check_budget "$1" && return 0
  done
  log "WARN: cannot free enough for $1"; return 1
}

# ── Handle mode: called by socat per connection ─────────────────────
if [ "$1" = "handle" ]; then
  read -r method path _ver
  method=$(printf '%s' "$method" | tr -d '\r')
  path=$(printf '%s' "$path" | tr -d '\r')
  while read -r hdr; do hdr=$(printf '%s' "$hdr" | tr -d '\r'); [ -z "$hdr" ] && break; done

  case "$method $path" in
    "GET /health")
      printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"ok"}';;
    "GET /status")
      thr=$(get_threshold); cur=$(get_total_actual_memory); avail=$(echo "$thr-$cur"|bc -l)
      svcs="{"; first=true
      for s in $(list_on_demand_services); do
        is_service_running "$s" && st="running" || st="stopped"
        $first && first=false || svcs="$svcs,"
        svcs="$svcs\"$s\":{\"state\":\"$st\",\"budget_gb\":$(get_service_budget "$s"),\"priority\":$(get_service_priority "$s")}"
      done; svcs="$svcs}"
      printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"total_memory_gb":24,"used_gb":%s,"available_gb":%s,"threshold_gb":%s,"services":%s}' "$cur" "$avail" "$thr" "$svcs";;
    "POST /start/"*)
      svc="${path#/start/}"; log "API: start $svc"
      if is_service_running "$svc"; then printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"already_running","service":"%s"}' "$svc"
      elif check_budget "$svc"; then start_service "$svc"; printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"started","service":"%s"}' "$svc"
      elif evict_for "$svc"; then start_service "$svc"; printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"started_after_eviction","service":"%s"}' "$svc"
      else printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"insufficient_resources","service":"%s"}' "$svc"; fi;;
    "POST /stop/"*)
      svc="${path#/stop/}"; log "API: stop $svc"; stop_service "$svc"
      printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"stopped","service":"%s"}' "$svc";;
    *)
      printf 'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"error":"not_found"}';;
  esac
  exit 0
fi

# ── Daemon mode (default) ───────────────────────────────────────────
log "Orchestrator starting (port $API_PORT)"
log "Manifest: $(jq -r '.vm.total_memory_gb' "$MANIFEST")GB total, threshold $(get_threshold)GB"

# Background OOM guard
(while true; do
  sleep 30
  cur=$(get_total_actual_memory)
  emg=$(echo "$(jq -r '.vm.total_memory_gb' "$MANIFEST") * 0.90" | bc -l)
  if echo "$cur $emg" | awk '{exit($1>$2)?0:1}'; then
    log "EMERGENCY: ${cur}GB used"
    worst_pri=0; worst_svc=""
    for s in $(list_on_demand_services); do
      is_service_running "$s" || continue
      p=$(get_service_priority "$s"); [ "$p" -gt "$worst_pri" ] && { worst_pri=$p; worst_svc=$s; }
    done
    [ -n "$worst_svc" ] && { log "Emergency stop: $worst_svc"; stop_service "$worst_svc"; }
  fi
  tick=$(cat "$STATE_DIR/tick" 2>/dev/null || echo 0); tick=$((tick+1)); echo "$tick">"$STATE_DIR/tick"
  [ $((tick%10)) -eq 0 ] && log "Status: ${cur}GB used"
done) &

# HTTP API via socat (forks to self with "handle" arg)
log "API listening on 0.0.0.0:$API_PORT"
exec socat TCP-LISTEN:$API_PORT,reuseaddr,fork EXEC:"/app/orchestrator.sh handle"
