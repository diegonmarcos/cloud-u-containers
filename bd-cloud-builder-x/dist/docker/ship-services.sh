#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ship-services.sh — Self-contained service deploy inside         ║
# ║  cloud-builder. GHA only passes env vars.                        ║
# ║                                                                  ║
# ║  This script: repos → WG → SSH → SOPS → build.sh ship           ║
# ║                                                                  ║
# ║  Required env:                                                   ║
# ║    VM, SOPS_AGE_KEY, GITHUB_TOKEN, GITHUB_ACTOR,                ║
# ║    GITHUB_REPOSITORY, CHANGED_DIRS (optional)                   ║
# ║  SSH keys: OCI_SSH_KEY, GCP_PROXY_SSH_KEY, GCP_T4_SSH_KEY       ║
# ║  WireGuard: WG_PRIVATE_KEY (optional, enables WG mesh)          ║
# ╚══════════════════════════════════════════════════════════════════╝
set -u  # no -e: parallel jobs must not kill the script on failure

VM="${VM:?VM env var required}"
FILTER="${FILTER:-}"
CHANGED_DIRS="${CHANGED_DIRS:-}"

# ── 0. Source nix profile + PATH ─────────────────────────────────
[ -f /etc/devshell-path.txt ] && export PATH="$(cat /etc/devshell-path.txt)"
[ -f /root/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . /root/.nix-profile/etc/profile.d/hm-session-vars.sh 2>/dev/null
export PATH="$HOME/.nix-profile/bin:$HOME/.node_modules/node_modules/.bin:${PATH:-/usr/bin:/bin}"

echo "══════════════════════════════════════════"
echo "  Ship Services → $VM"
echo "══════════════════════════════════════════"

# ── 1. Clone/refresh repos ───────────────────────────────────────
mkdir -p ~/.ssh
ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null
git config --global --add safe.directory "*"

REPO="https://github.com/${GITHUB_REPOSITORY:?}.git"
if [ -d /workspace/.git ]; then
  echo "[1/6] Using existing /workspace"
  cd /workspace
  git pull --ff-only 2>/dev/null || true
else
  echo "[1/6] Cloning $REPO"
  git clone --depth 2 --recurse-submodules "$REPO" /workspace
  cd /workspace
fi
git submodule update --remote
git -C cloud-data fetch origin main 2>/dev/null && git -C cloud-data reset --hard origin/main 2>/dev/null || true

# ── 2. WireGuard (if key provided) ──────────────────────────────
if [ -n "${WG_PRIVATE_KEY:-}" ]; then
  echo "[2/6] Setting up WireGuard"
  umask 077
  cat > /tmp/wg0.conf << WGEOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = 10.0.0.200/24

[Peer]
PublicKey = vV/phXUwnCjxACQ5Df11Uw47BzJaK4r85jPYMu2HmDc=
Endpoint = 35.226.147.64:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
WGEOF
  mkdir -p /etc/wireguard
  cp /tmp/wg0.conf /etc/wireguard/wg0.conf
  rm /tmp/wg0.conf
  wg-quick up wg0
  ping -c1 -W3 10.0.0.1 >/dev/null 2>&1 && echo "[wg] Hub reachable" || echo "[wg] Hub not reachable (may need time)"
else
  echo "[2/6] WireGuard skipped (no WG_PRIVATE_KEY)"
fi

# ── 3. SSH setup ─────────────────────────────────────────────────
echo "[3/6] Setting up SSH for $VM"
GHA_CONFIG="cloud-data/cloud-data-gha-config.json"
if [ ! -f "$GHA_CONFIG" ]; then
  echo "FATAL: $GHA_CONFIG not found"
  exit 1
fi

# Use WG IP if WireGuard is up, otherwise fall back to public IP
if ip link show wg0 >/dev/null 2>&1; then
  HOST=$(jq -r --arg vm "$VM" '.vms[$vm].wg_ip // .vms[$vm].host' "$GHA_CONFIG")
else
  HOST=$(jq -r --arg vm "$VM" '.vms[$vm].host // empty' "$GHA_CONFIG")
fi
USER=$(jq -r --arg vm "$VM" '.vms[$vm].user // "ubuntu"' "$GHA_CONFIG")

if [ -z "$HOST" ] || [ "$HOST" = "null" ]; then
  echo "FATAL: No host found for VM=$VM in $GHA_CONFIG"
  exit 1
fi

# SSH key: select by VM
case "$VM" in
  gcp-proxy) KEY_VAR="${GCP_PROXY_SSH_KEY:-}" ;;
  gcp-t4)    KEY_VAR="${GCP_T4_SSH_KEY:-}" ;;
  *)         KEY_VAR="${OCI_SSH_KEY:-}" ;;
esac

if [ -z "$KEY_VAR" ]; then
  echo "FATAL: No SSH key for $VM"
  exit 1
fi

echo "$KEY_VAR" > ~/.ssh/id_deploy
chmod 600 ~/.ssh/id_deploy
cat > ~/.ssh/config <<EOF
Host ${VM}
  HostName ${HOST}
  User ${USER}
  IdentityFile ~/.ssh/id_deploy
  StrictHostKeyChecking no
  ServerAliveInterval 30
  ServerAliveCountMax 10
EOF
chmod 600 ~/.ssh/config
echo "[ssh] $VM → $HOST ($USER)"

# ── 4. SOPS setup ───────────────────────────────────────────────
echo "[4/6] Setting up SOPS"
if [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -f "$SOPS_AGE_KEY_FILE" ]; then
  export SOPS_AGE_KEY_FILE
elif [ ! -f ~/.config/sops/age/keys.txt ]; then
  mkdir -p ~/.config/sops/age
  echo "${SOPS_AGE_KEY:?SOPS_AGE_KEY required}" > ~/.config/sops/age/keys.txt
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
else
  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
fi

# ── 5. GHCR login ───────────────────────────────────────────────
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin 2>/dev/null
fi

# ── 6. Ship services ────────────────────────────────────────────
echo "[5/6] Resolving services for $VM"
SERVICES=$(jq -r --arg vm "$VM" '
  .services | to_entries[]
  | select(.value.vm == $vm)
  | [.value.dir, .key]
  | join("|")
' "$GHA_CONFIG")

if [ -z "$SERVICES" ]; then
  echo "No services found for VM: $VM"
  exit 0
fi

[ -n "$CHANGED_DIRS" ] && echo "Changed dirs: $CHANGED_DIRS"

TOTAL=$(echo "$SERVICES" | wc -l)
_CORES=$(nproc 2>/dev/null || echo 2)
MAX_PARALLEL="${SHIP_PARALLEL:-$(( _CORES > 1 ? _CORES - 1 : 1 ))}"

# SSH multiplex master
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-mux-%r@%h:%p -o ControlPersist=300 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"
ssh $SSH_OPTS -fNM "$VM" 2>/dev/null && echo "[ssh] Multiplex master established" || echo "[ssh] Multiplex failed (will retry per-service)"

# Pre-stage cloud-data into services
CLOUD_DATA_DIR="/workspace/cloud-data"
CLOUD_DATA_PRESTAGED=""
if [ -d "$CLOUD_DATA_DIR" ]; then
  while IFS='|' read -r dir name; do
    SVC_DIR="/workspace/a_solutions/$dir"
    BUILD_JSON="$SVC_DIR/build.json"
    [ -f "$BUILD_JSON" ] || continue
    INCLUDE=$(node -e "try{const c=require('$BUILD_JSON');process.stdout.write(String(c.build?.include_cloud_data||''))}catch{}" 2>/dev/null)
    [ "$INCLUDE" = "true" ] || continue
    SRC="$SVC_DIR/src"
    [ -d "$SRC" ] || continue
    for f in "$CLOUD_DATA_DIR"/*.json; do
      [ -f "$f" ] || continue
      BASENAME=$(basename "$f")
      TARGET="$SRC/$BASENAME"
      REL=$(realpath --relative-to="/workspace" "$TARGET")
      git -C /workspace ls-files --error-unmatch "$REL" >/dev/null 2>&1 && continue
      cp "$f" "$TARGET"
      CLOUD_DATA_PRESTAGED="$CLOUD_DATA_PRESTAGED $TARGET"
    done
  done <<< "$SERVICES"
  if [ -n "$CLOUD_DATA_PRESTAGED" ]; then
    RELS=""
    for t in $CLOUD_DATA_PRESTAGED; do
      RELS="$RELS $(realpath --relative-to="/workspace" "$t")"
    done
    git -C /workspace add -f $RELS
    echo "Staged $(echo $CLOUD_DATA_PRESTAGED | wc -w) cloud-data files"
  fi
  export CLOUD_DATA_PRESTAGED_BY_CI=true
fi

echo "[6/6] Shipping $TOTAL services (max $MAX_PARALLEL parallel)"
echo "═══════════════════════════════════════════════"

# Per-service worker
RUN_START=$(date +%s)
TRACE_SERVICES="[]"
RESULTS_DIR=$(mktemp -d)

ship_one() {
  local dir="$1" name="$2"
  local log_file="$RESULTS_DIR/${name}.log"
  local svc_start
  svc_start=$(date +%s)
  {
    echo "── Ship: $name ($dir) ──"
    BUILD_SH="a_solutions/${dir}/build.sh"
    if [ ! -f "$BUILD_SH" ]; then
      echo "SKIP $name (no build.sh)"
      echo "skip" > "$RESULTS_DIR/${name}.status"
      echo "0" > "$RESULTS_DIR/${name}.dur"
      return 0
    fi
    if bash "$BUILD_SH" ship; then
      echo "OK $name"
      echo "ok" > "$RESULTS_DIR/${name}.status"
    else
      echo "FAIL $name (exit $?)"
      echo "fail" > "$RESULTS_DIR/${name}.status"
    fi
  } 2>&1 | stdbuf -oL sed "s/^/[$name] /" | tee "$log_file"
  echo "$(( $(date +%s) - svc_start ))" > "$RESULTS_DIR/${name}.dur"
}

# Launch in parallel
SHIP_CMDS=$(mktemp)
while IFS='|' read -r dir name; do
  [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
  if [ -n "$CHANGED_DIRS" ] && ! echo "$CHANGED_DIRS" | grep -q "$dir"; then
    echo "SKIP $name (unchanged)"
    echo "skip" > "$RESULTS_DIR/${name}.status"
    echo "0" > "$RESULTS_DIR/${name}.dur"
    continue
  fi
  echo "$dir|$name" >> "$SHIP_CMDS"
done <<< "$SERVICES"

export -f ship_one
export RESULTS_DIR

cat "$SHIP_CMDS" | xargs -P "$MAX_PARALLEL" -I{} bash -c '
  IFS="|" read -r dir name <<< "{}"
  ship_one "$dir" "$name"
'
rm -f "$SHIP_CMDS"

# Cleanup pre-staged cloud-data
if [ -n "${CLOUD_DATA_PRESTAGED:-}" ]; then
  for t in $CLOUD_DATA_PRESTAGED; do
    REL=$(realpath --relative-to="/workspace" "$t" 2>/dev/null || true)
    [ -n "$REL" ] && git -C /workspace reset HEAD "$REL" 2>/dev/null || true
    rm -f "$t"
  done
fi

# Collect results
OK=0; FAIL=0; SKIP=0
while IFS='|' read -r dir name; do
  [ -n "$FILTER" ] && [ "$dir" != "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
  status=$(cat "$RESULTS_DIR/${name}.status" 2>/dev/null || echo "fail")
  dur=$(cat "$RESULTS_DIR/${name}.dur" 2>/dev/null || echo "0")
  case "$status" in
    ok)   OK=$((OK + 1)) ;;
    skip) SKIP=$((SKIP + 1)) ;;
    *)    FAIL=$((FAIL + 1)) ;;
  esac
  TRACE_SERVICES=$(jq --arg n "$name" --arg d "$dir" --arg s "$status" --argjson dur "$dur" \
    '. + [{"name":$n,"dir":$d,"status":$s,"duration_s":$dur}]' <<< "$TRACE_SERVICES")
done <<< "$SERVICES"
rm -rf "$RESULTS_DIR"

echo ""
echo "═══════════════════════════════════════════════"
echo "Ship → $VM: $OK ok, $FAIL failed, $SKIP skipped (of $TOTAL)"

# Write trace JSON
RUN_DUR=$(( $(date +%s) - RUN_START ))
RUN_STATUS="success"; [ "$FAIL" -gt 0 ] && RUN_STATUS="failure"
TRACE_DIR="${TRACE_DIR:-/traces}"
mkdir -p "$TRACE_DIR"
jq -n \
  --arg vm "$VM" \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  --arg run_url "https://github.com/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}" \
  --arg sha "${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}" \
  --arg trigger "${GITHUB_EVENT_NAME:-manual}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson dur "$RUN_DUR" \
  --argjson total "$TOTAL" \
  --argjson ok "$OK" \
  --argjson fail "$FAIL" \
  --argjson skip "$SKIP" \
  --arg status "$RUN_STATUS" \
  --argjson services "$TRACE_SERVICES" \
  '{vm:$vm,run_id:$run_id,run_url:$run_url,sha:$sha,trigger:$trigger,ts:$ts,duration_s:$dur,total:$total,ok:$ok,fail:$fail,skip:$skip,status:$status,services:$services}' \
  > "$TRACE_DIR/${VM}.json"

echo "Trace: $TRACE_DIR/${VM}.json"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
