#!/bin/bash
# WireGuard mesh deployment pipeline
# build → secrets → inject → deploy → compose
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"

# Age key - auto-detect mobile vs desktop
if [ -f "$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=$HOME/git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
elif [ -f "/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt" ]; then
    : "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/providers/system/oauth/age_keys.txt}"
fi
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
err() { log "ERROR: $1" >&2; return 1; }

# ── JSON config reader ──────────────────────────────────────────────────
# Read build.json via node (primary) or python3 (fallback)
json_get() {
    local query="$1"
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); console.log($query)" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); print($query)" 2>/dev/null
    else
        err "No node or python3 for JSON parsing"
    fi
}

# Get list of VM names
vm_list() {
    json_get "Object.keys(c.vms).join('\n')"
}

# Get VM property: vm_prop <vm> <field>
vm_prop() {
    json_get "c.vms['$1'].$2 || c.vms['$1']['$2']"
}

# Resolve target VMs: all or single
resolve_vms() {
    if [ -n "$1" ]; then
        # Validate VM name exists
        vm_list | grep -qx "$1" || err "Unknown VM: $1 (valid: $(vm_list | tr '\n' ' '))"
        echo "$1"
    else
        vm_list
    fi
}

# ── Step: build ─────────────────────────────────────────────────────────
step_build() {
    log "Building nix flake → dist/"
    cd "$SRC_DIR"

    nix build --out-link "$SERVICE_DIR/.result"

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    log "Built templates:"
    ls -1 "$DIST_DIR"/wg0-*.conf 2>/dev/null | while read -r f; do
        printf "  %s\n" "$(basename "$f")"
    done
}

# ── Step: secrets ───────────────────────────────────────────────────────
step_secrets() {
    local secrets_file="$SRC_DIR/secrets.yaml"
    [ -f "$secrets_file" ] || err "No secrets.yaml found"

    log "Decrypting secrets → dist/.env"
    mkdir -p "$DIST_DIR"

    if command -v yq >/dev/null 2>&1; then
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$DIST_DIR/.env"
    elif command -v python3 >/dev/null 2>&1; then
        sops -d "$secrets_file" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('sops:'):
        break
    if not line or line.startswith('#'):
        continue
    if ':' in line:
        k, v = line.split(':', 1)
        k, v = k.strip(), v.strip().strip('\"').strip(\"'\")
        if v:
            print(f'{k}={v}')
" > "$DIST_DIR/.env"
    else
        err "No yq or python3 for YAML→env conversion"
    fi

    log "Secrets decrypted ($(grep -c '=' "$DIST_DIR/.env" 2>/dev/null || echo 0) keys)"
}

# ── Step: deploy ────────────────────────────────────────────────────────
# Injects private keys in-memory (from .env) and pipes directly to VM via ssh
# No decrypted keys ever written to disk beyond .env (which is gitignored)
step_deploy() {
    [ -f "$DIST_DIR/.env" ] || err "No dist/.env — run 'secrets' first"

    # Load .env into memory
    set -a
    . "$DIST_DIR/.env"
    set +a

    local vms
    vms="$(resolve_vms "${1:-}")"

    echo "$vms" | while read -r vm; do
        local template="$DIST_DIR/wg0-${vm}.conf"
        [ -f "$template" ] || { log "SKIP: no template for $vm"; continue; }

        local ssh_host env_var privkey
        ssh_host="$(vm_prop "$vm" "ssh_host")"
        env_var="$(vm_prop "$vm" "privkey_env")"
        eval "privkey=\$$env_var"
        [ -n "$privkey" ] || err "No private key for $vm (env: $env_var)"

        log "Deploying wg0.conf → $vm ($ssh_host)"
        # Inject key in-memory, pipe directly to remote via ssh
        sed "s|__PRIVKEY__|${privkey}|" "$template" | \
            ssh "$ssh_host" "sudo tee /etc/wireguard/wg0.conf > /dev/null && sudo chmod 600 /etc/wireguard/wg0.conf && sudo chown root:root /etc/wireguard/wg0.conf"
        log "  $vm: deployed"
    done
}

# ── Step: compose ───────────────────────────────────────────────────────
step_compose() {
    local vms
    vms="$(resolve_vms "${1:-}")"

    echo "$vms" | while read -r vm; do
        local ssh_host
        ssh_host="$(vm_prop "$vm" "ssh_host")"

        log "Restarting wg-quick@wg0 on $vm"
        ssh "$ssh_host" "sudo systemctl restart wg-quick@wg0"
        log "  $vm: restarted"
    done
}

# ── Step: ship (all-in-one) ─────────────────────────────────────────────
step_ship() {
    local target="${1:-}"

    # Build + secrets, then deploy (keys injected in-memory)
    step_build
    step_secrets
    step_deploy "$target"
    step_compose "$target"

    log "Ship complete"
    step_status "$target"
}

# ── Step: status ────────────────────────────────────────────────────────
step_status() {
    local vms
    vms="$(resolve_vms "${1:-}")"

    echo "$vms" | while read -r vm; do
        local ssh_host
        ssh_host="$(vm_prop "$vm" "ssh_host")"

        echo "── $vm ──────────────────────────────"
        ssh "$ssh_host" "sudo wg show wg0" 2>&1 || echo "  (unreachable)"
        echo ""
    done
}

# ── Step: diff ──────────────────────────────────────────────────────────
# Compares local templates vs remote configs (keys redacted on both sides)
step_diff() {
    local vms
    vms="$(resolve_vms "${1:-}")"

    echo "$vms" | while read -r vm; do
        local template="$DIST_DIR/wg0-${vm}.conf"
        local ssh_host
        ssh_host="$(vm_prop "$vm" "ssh_host")"

        echo "── $vm ──────────────────────────────"

        if [ ! -f "$template" ]; then
            log "  No local template — run 'build' first"
            continue
        fi

        # Fetch remote, redact keys on both sides for safe comparison
        local remote_conf
        remote_conf="$(ssh "$ssh_host" "sudo cat /etc/wireguard/wg0.conf" 2>/dev/null)" || {
            log "  (unreachable)"
            continue
        }

        local local_redacted remote_redacted
        local_redacted="$(sed 's/PrivateKey = .*/PrivateKey = [REDACTED]/' < "$template")"
        remote_redacted="$(echo "$remote_conf" | sed 's/PrivateKey = .*/PrivateKey = [REDACTED]/')"

        if [ "$local_redacted" = "$remote_redacted" ]; then
            log "  $vm: in sync"
        else
            diff <(echo "$local_redacted") <(echo "$remote_redacted") || true
        fi
    done
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  WireGuard Mesh Deployer               ║"
echo "╚════════════════════════════════════════╝"

cmd="${1:-}"
target="${2:-}"

case "$cmd" in
    build)    step_build ;;
    secrets)  step_secrets ;;
    deploy)   step_deploy "$target" ;;
    compose)  step_compose "$target" ;;
    ship)     step_ship "$target" ;;
    status)   step_status "$target" ;;
    diff)     step_diff "$target" ;;
    clean)    rm -rf "$DIST_DIR/.env" "$SERVICE_DIR/.result"; log "Cleaned" ;;
    *)
        cat <<'USAGE'
Usage: ./build.sh <command> [vm]

Commands:
  build              Build nix flake → dist/wg0-*.conf (templates)
  secrets            Decrypt secrets.yaml → dist/.env (gitignored)
  deploy  [vm]       Inject keys in-memory + SCP to VM(s)
  compose [vm]       Restart wg-quick@wg0 on VM(s)
  ship    [vm]       All of the above (build→secrets→deploy→compose)
  status  [vm]       Show wg show wg0 on VM(s)
  diff    [vm]       Compare local vs remote configs (keys redacted)
  clean              Remove dist/.env

VMs: gcp-proxy, oci-flex, oci-mail, oci-analytics
Omit [vm] to target all VMs.
USAGE
        ;;
esac
