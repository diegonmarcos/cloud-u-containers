#!/bin/sh
# Convert docker-compose.yml → docker-run.sh (POSIX shell + jq, no Python)
# Runs on desktop/GHA only. Output is pure sh — safe for E2 Micros.
# Usage: ./_compose-to-run.sh [docker-compose.yml] > docker-run.sh
set -eu

INPUT="${1:-docker-compose.yml}"
[ -f "$INPUT" ] || { echo "ERROR: $INPUT not found" >&2; exit 1; }

# Get resolved JSON from compose (runs Go binary on desktop — fine, has RAM)
JSON=$(docker compose -f "$INPUT" config --format json 2>/dev/null) || {
  echo "ERROR: docker compose config failed" >&2; exit 1
}

# Fix: docker compose config resolves relative volume paths to absolute (build-machine CWD).
# On the VM, docker-run.sh runs from the deploy directory, so paths must be relative.
BUILD_CWD=$(pwd)
JSON=$(echo "$JSON" | jq --arg cwd "$BUILD_CWD" '
  .services |= with_entries(
    .value.volumes //= [] |
    .value.volumes |= map(
      if type == "object" and (.source | startswith($cwd + "/")) then
        .source = "./" + (.source | ltrimstr($cwd + "/"))
      elif type == "object" and (.source == $cwd) then
        .source = "."
      else . end
    )
  )
')

# Fix: docker compose config inlines env_file into environment and drops env_file.
# If .secrets is empty at build time (secrets step hasn't run yet), env vars are lost.
# Re-inject env_file per-service from the original YAML so docker-run.sh uses --env-file.
# Parse original YAML: map service → env_file entries (handles standard compose format)
SVC_ENVFILES=$(awk '
  /^services:/ { in_svc=1; next }
  in_svc && /^[^ ]/ { in_svc=0 }
  in_svc && /^  [a-zA-Z_-]+:/ { sub(/:.*/, ""); gsub(/^ +/, ""); cur=$0; in_ef=0 }
  in_svc && /^ *env_file:/ { in_ef=1; next }
  in_svc && in_ef && /^ *- / { f=$0; gsub(/^ *- */, "", f); gsub(/ *$/, "", f); if(cur && f) print cur "=" f; next }
  in_svc && in_ef && !/^ *- / && !/^ *#/ { in_ef=0 }
' "$INPUT" 2>/dev/null) || true

if [ -n "$SVC_ENVFILES" ]; then
  # Build JSON: {"caddy": [".secrets"], ...}
  EF_JSON=$(printf '%s\n' "$SVC_ENVFILES" | jq -R -s '
    split("\n") | map(select(length > 0)) |
    map(split("=") | {key: .[0], value: .[1]}) |
    group_by(.key) | map({key: .[0].key, value: [.[].value]}) |
    from_entries
  ')
  JSON=$(echo "$JSON" | jq --argjson ef "$EF_JSON" '
    .services |= with_entries(
      if $ef[.key] then .value.env_file = $ef[.key] else . end
    )
  ')
fi

PROJECT=$(echo "$JSON" | jq -r '.name // "unknown"')
SERVICES=$(echo "$JSON" | jq -r '.services | keys[]')
SVC_COUNT=$(echo "$SERVICES" | wc -l)

# ── Header ──
cat <<EOF
#!/bin/sh
# Auto-generated from docker-compose.yml — DO NOT EDIT
# Run this instead of 'docker compose up' on E2 Micro VMs (1GB RAM)
# Project: $PROJECT | Services: $SVC_COUNT
set -e
EOF

# ── Volumes ──
VOLS=$(echo "$JSON" | jq -r '(.volumes // {}) | to_entries[] | select(.value.external != true) | .key')
if [ -n "$VOLS" ]; then
  echo ""
  echo "# Create volumes"
  echo "$VOLS" | while IFS= read -r v; do
    [ -z "$v" ] && continue
    echo "docker volume create $v 2>/dev/null || true"
  done
fi

# ── Networks ──
NETS=$(echo "$JSON" | jq -r '(.networks // {}) | to_entries[] | select(.value.external != true) | .key')
if [ -n "$NETS" ]; then
  echo ""
  echo "# Create networks"
  echo "$NETS" | while IFS= read -r n; do
    [ -z "$n" ] && continue
    DRIVER=$(echo "$JSON" | jq -r ".networks[\"$n\"].driver // empty")
    if [ -n "$DRIVER" ]; then
      echo "docker network create --driver $DRIVER $n 2>/dev/null || true"
    else
      echo "docker network create $n 2>/dev/null || true"
    fi
  done
fi

# ── Pull images ──
IMAGES=$(echo "$JSON" | jq -r '.services[].image // empty' | sort -u)
if [ -n "$IMAGES" ]; then
  echo ""
  echo "# Pull latest images"
  echo "$IMAGES" | while IFS= read -r img; do
    [ -z "$img" ] && continue
    echo "echo \"  pull: $img\""
    echo "docker pull $img 2>/dev/null || true"
  done
fi

# ── Services (dependency order via jq topo sort) ──
echo ""

# For each service, generate docker run command
echo "$JSON" | jq -r '
  .services | to_entries[] |
  .key as $name | .value as $svc |

  # Skip services without image
  if ($svc.image // null) == null then
    "# SKIP \($name): no image (needs build.sh ship first)"
  else
    "# --- \($name) ---\n" +
    "docker rm -f \($svc.container_name // $name) 2>/dev/null || true\n" +
    "docker run -d" +

    # Name
    " --name \($svc.container_name // $name)" +

    # Labels
    " --label com.docker.compose.project=\(.key)" +
    " --label com.docker.compose.service=\($name)" +

    # Network mode
    (if $svc.network_mode then " --network \($svc.network_mode)" else
      ($svc.networks // {} | keys | map(" --network \(.)") | join(""))
    end) +

    # Ports
    ($svc.ports // [] | map(
      if type == "object" then
        " -p \(.published // .target):\(.target)\(if .protocol and .protocol != "tcp" then "/\(.protocol)" else "" end)"
      else " -p \(.)" end
    ) | join("")) +

    # Read-only rootfs
    (if $svc.read_only then " --read-only" else "" end) +

    # tmpfs
    ($svc.tmpfs // [] | map(" --tmpfs \(.)") | join("")) +

    # DNS
    ($svc.dns // [] | map(" --dns \(.)") | join("")) +

    # Volumes
    ($svc.volumes // [] | map(
      if type == "object" then
        " -v \(.source):\(.target)\(if .read_only then ":ro" else "" end)"
      else " -v \(.)" end
    ) | join("")) +

    # Ulimits
    (if $svc.ulimits then
      ($svc.ulimits | to_entries | map(
        if .value | type == "object" then
          " --ulimit \(.key)=\(.value.soft):\(.value.hard)"
        else
          " --ulimit \(.key)=\(.value)"
        end
      ) | join(""))
    else "" end) +

    # Environment
    (if ($svc.environment // null) | type == "object" then
      ($svc.environment | to_entries | map(
        if .value == null then " -e \(.key)"
        else " -e \"\(.key)=\(.value | tostring | gsub("\""; "\\\""))\"" end
      ) | join(""))
    else "" end) +

    # Env file
    ($svc.env_file // [] | map(
      if type == "object" then " --env-file \(.path)" else " --env-file \(.)" end
    ) | join("")) +

    # Resource limits
    (if $svc.deploy.resources.limits.memory then " --memory \($svc.deploy.resources.limits.memory)" else "" end) +
    (if $svc.deploy.resources.limits.cpus then " --cpus \($svc.deploy.resources.limits.cpus)" else "" end) +
    (if $svc.deploy.resources.reservations.memory then " --memory-reservation \($svc.deploy.resources.reservations.memory)" else "" end) +

    # Restart
    (if $svc.restart and $svc.restart != "no" then " --restart \($svc.restart)" else "" end) +

    # Healthcheck
    (if $svc.healthcheck.test then
      (if ($svc.healthcheck.test | type) == "array" then
        (if $svc.healthcheck.test[0] == "CMD-SHELL" then
          " --health-cmd \"\($svc.healthcheck.test[1] | gsub("\""; "\\\""))\""
        elif $svc.healthcheck.test[0] == "CMD" then
          " --health-cmd \"\($svc.healthcheck.test[1:] | join(" ") | gsub("\""; "\\\""))\""
        else "" end)
      else " --health-cmd \"\($svc.healthcheck.test)\"" end) +
      (if $svc.healthcheck.interval then " --health-interval \($svc.healthcheck.interval)" else "" end) +
      (if $svc.healthcheck.timeout then " --health-timeout \($svc.healthcheck.timeout)" else "" end) +
      (if $svc.healthcheck.retries then " --health-retries \($svc.healthcheck.retries)" else "" end)
    else "" end) +

    # Capabilities
    ($svc.cap_add // [] | map(" --cap-add \(.)") | join("")) +
    ($svc.cap_drop // [] | map(" --cap-drop \(.)") | join("")) +

    # Security
    ($svc.security_opt // [] | map(" --security-opt \(.)") | join("")) +

    # Hostname
    (if $svc.hostname then " --hostname \($svc.hostname)" else "" end) +

    # User
    (if $svc.user then " --user \($svc.user)" else "" end) +

    # Working dir
    (if $svc.working_dir then " -w \($svc.working_dir)" else "" end) +

    # Logging
    (if $svc.logging.driver then
      " --log-driver \($svc.logging.driver)" +
      ($svc.logging.options // {} | to_entries | map(" --log-opt \(.key)=\"\(.value)\"") | join(""))
    else "" end) +

    # Entrypoint + args (array entrypoint: [0] = --entrypoint, [1:] = args after image)
    (if $svc.entrypoint then
      (if ($svc.entrypoint | type) == "array" then
        " --entrypoint \"\($svc.entrypoint[0])\""
      else " --entrypoint \"\($svc.entrypoint)\"" end)
    else "" end) +

    # Image
    " \($svc.image)" +

    # Entrypoint args (elements [1:] of entrypoint array, placed after image)
    (if $svc.entrypoint and ($svc.entrypoint | type) == "array" and ($svc.entrypoint | length) > 1 then
      " \($svc.entrypoint[1:] | map(if contains(" ") then "\"\(.)\"" else . end) | join(" "))"
    # Command (only if entrypoint doesn't have args)
    elif $svc.command then
      (if ($svc.command | type) == "array" then
        " \($svc.command | map(if contains(" ") then "\"\(.)\"" else . end) | join(" "))"
      else " \($svc.command)" end)
    else "" end) +

    "\necho \"  started: \($svc.container_name // $name)\""
  end
' 2>/dev/null || echo "# ERROR: jq failed to convert services" >&2
