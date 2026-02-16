#!/usr/bin/env bash
# seed_from_config.sh - Populate SurrealDB KG from config.json
# Usage: ./seed_from_config.sh [surreal_url] [config_json_path]
#
# Reads config.json and generates SurrealQL to create:
#   - VM nodes (from vms section)
#   - Service nodes (from services section)
#   - hosted_on edges (service -> vm)
#
# Requires: curl, python3 (or node), surreal CLI (optional)
set -euo pipefail

SURREAL_URL="${1:-http://localhost:8001}"
CONFIG_JSON="${2:-/opt/containers/kg-graph/config.json}"
SURREAL_NS="infra"
SURREAL_DB="production"

# Read password from .secrets or env
if [ -f /opt/containers/kg-graph/.secrets ]; then
    source /opt/containers/kg-graph/.secrets
fi
SURREAL_PASS="${SURREAL_ROOT_PASSWORD:-root}"

log() { echo "[seed] $*"; }

# WireGuard IP mapping (hardcoded from cloud architecture)
declare -A WG_IPS=(
    ["gcp-E2-f_0"]="10.0.0.1"
    ["oci-A1-f_1"]="10.0.0.2"
    ["oci-E2-f_0"]="10.0.0.3"
    ["oci-E2-f_1"]="10.0.0.4"
    ["oci-A1-f_0"]="10.0.0.6"
    ["oci-A1-p_0"]="10.0.0.7"
)

# VM metadata (arch, cpu, ram) not in config.json
declare -A VM_ARCH=(
    ["gcp-E2-f_0"]="x86_64"
    ["oci-E2-f_0"]="x86_64"
    ["oci-E2-f_1"]="x86_64"
    ["oci-A1-f_0"]="aarch64"
    ["oci-A1-f_1"]="aarch64"
    ["oci-A1-p_0"]="aarch64"
)
declare -A VM_CPU=(
    ["gcp-E2-f_0"]="1"
    ["oci-E2-f_0"]="2"
    ["oci-E2-f_1"]="2"
    ["oci-A1-f_0"]="3"
    ["oci-A1-f_1"]="1"
    ["oci-A1-p_0"]="8"
)
declare -A VM_RAM=(
    ["gcp-E2-f_0"]="1"
    ["oci-E2-f_0"]="1"
    ["oci-E2-f_1"]="1"
    ["oci-A1-f_0"]="16"
    ["oci-A1-f_1"]="8"
    ["oci-A1-p_0"]="32"
)

# Known service domains (extracted from CLAUDE.md / architecture)
declare -A SVC_DOMAINS=(
    ["authelia"]="auth.diegonmarcos.com"
    ["vaultwarden"]="vault.diegonmarcos.com"
    ["ntfy"]="rss.diegonmarcos.com"
    ["mailu"]="mail.diegonmarcos.com"
    ["syncthing"]="sync.diegonmarcos.com"
    ["radicale"]="cal.diegonmarcos.com"
    ["matomo"]="analytics.diegonmarcos.com"
    ["photoprism"]="photos.diegonmarcos.com"
    ["nocodb"]="db.diegonmarcos.com"
    ["code-server"]="ide.diegonmarcos.com"
    ["affine"]="drive-notes-affine.diegonmarcos.com"
    ["windmill"]="windmill.diegonmarcos.com"
    ["grist"]="sheets.diegonmarcos.com"
    ["revealmd"]="slides.diegonmarcos.com"
    ["npm"]="proxy.diegonmarcos.com"
    ["flask-api"]="api.diegonmarcos.com"
    ["hickory-dns"]="dns.internal"
)

surreal_query() {
    curl -sf "${SURREAL_URL}/sql" \
        -H "Accept: application/json" \
        -H "surreal-ns: ${SURREAL_NS}" \
        -H "surreal-db: ${SURREAL_DB}" \
        -u "root:${SURREAL_PASS}" \
        --data-raw "$1" || { echo "FAILED: $1" >&2; return 1; }
}

# ---- Load schema ----
log "Loading schema..."
if [ -f /opt/containers/kg-graph/schema.surql ]; then
    SCHEMA=$(cat /opt/containers/kg-graph/schema.surql)
    surreal_query "$SCHEMA" > /dev/null
    log "Schema loaded."
else
    log "WARNING: schema.surql not found, skipping schema load."
fi

# ---- Parse config.json and generate seed data ----
log "Parsing config.json..."

if ! [ -f "$CONFIG_JSON" ]; then
    # Try local path relative to script
    CONFIG_JSON="$(dirname "$0")/../config.json"
    if ! [ -f "$CONFIG_JSON" ]; then
        log "ERROR: config.json not found at $CONFIG_JSON"
        exit 1
    fi
fi

# Generate SurrealQL using python3
SEED_SQL=$(python3 << 'PYEOF'
import json, sys, os

config_path = os.environ.get("CONFIG_JSON", "/opt/containers/kg-graph/config.json")
with open(config_path) as f:
    config = json.load(f)

wg_ips = {
    "gcp-E2-f_0": "10.0.0.1", "oci-A1-f_1": "10.0.0.2",
    "oci-E2-f_0": "10.0.0.3", "oci-E2-f_1": "10.0.0.4",
    "oci-A1-f_0": "10.0.0.6", "oci-A1-p_0": "10.0.0.7",
}
vm_arch = {
    "gcp-E2-f_0": "x86_64", "oci-E2-f_0": "x86_64", "oci-E2-f_1": "x86_64",
    "oci-A1-f_0": "aarch64", "oci-A1-f_1": "aarch64", "oci-A1-p_0": "aarch64",
}
vm_cpu = {
    "gcp-E2-f_0": 1, "oci-E2-f_0": 2, "oci-E2-f_1": 2,
    "oci-A1-f_0": 3, "oci-A1-f_1": 1, "oci-A1-p_0": 8,
}
vm_ram = {
    "gcp-E2-f_0": 1, "oci-E2-f_0": 1, "oci-E2-f_1": 1,
    "oci-A1-f_0": 16, "oci-A1-f_1": 8, "oci-A1-p_0": 32,
}
svc_domains = {
    "authelia": "auth.diegonmarcos.com",
    "vaultwarden": "vault.diegonmarcos.com",
    "ntfy": "rss.diegonmarcos.com",
    "mailu": "mail.diegonmarcos.com",
    "syncthing": "sync.diegonmarcos.com",
    "radicale": "cal.diegonmarcos.com",
    "matomo": "analytics.diegonmarcos.com",
    "photoprism": "photos.diegonmarcos.com",
    "nocodb": "db.diegonmarcos.com",
    "code-server": "ide.diegonmarcos.com",
    "affine": "drive-notes-affine.diegonmarcos.com",
    "windmill": "windmill.diegonmarcos.com",
    "grist": "sheets.diegonmarcos.com",
    "revealmd": "slides.diegonmarcos.com",
    "npm": "proxy.diegonmarcos.com",
    "flask-api": "api.diegonmarcos.com",
    "hickory-dns": "dns.internal",
}

stmts = []

# --- VM nodes ---
for vm_id, vm in config["vms"].items():
    if vm.get("ip", "TBD") == "TBD":
        continue  # Skip vast.ai (no fixed IP)
    provider = "gcp" if vm_id.startswith("gcp") else "oci"
    alias = vm.get("ssh_alias", vm_id)
    esc_desc = vm.get("description", "").replace("'", "\\'")
    wg = wg_ips.get(vm_id, "")
    arch = vm_arch.get(vm_id, "")
    cpu = vm_cpu.get(vm_id, 0)
    ram = vm_ram.get(vm_id, 0)

    stmts.append(f"""CREATE vm:{vm_id.replace('-','_')} CONTENT {{
    name: '{vm_id}',
    alias: '{alias}',
    ip: '{vm["ip"]}',
    wg_ip: {f"'{wg}'" if wg else "NONE"},
    user: '{vm["user"]}',
    provider: '{provider}',
    arch: {f"'{arch}'" if arch else "NONE"},
    cpu_count: {cpu if cpu else "NONE"},
    ram_gb: {ram if ram else "NONE"},
    disk_gb: NONE,
    description: '{esc_desc}',
    status: 'unknown',
    embedding: NONE,
    updated_at: time::now()
}};""")

# --- Service nodes ---
for svc_name, svc in config["services"].items():
    if svc.get("vm") == "all" or svc.get("vm") == "local":
        continue  # Skip wireguard (all) and terraform (local)
    esc_desc = svc.get("description", "").replace("'", "\\'")
    domain = svc_domains.get(svc_name, "")
    safe_id = svc_name.replace("-", "_")

    stmts.append(f"""CREATE service:{safe_id} CONTENT {{
    name: '{svc_name}',
    category: '{svc["category"]}',
    description: '{esc_desc}',
    domain: {f"'{domain}'" if domain else "NONE"},
    port: NONE,
    availability: 'unknown',
    status: 'unknown',
    embedding: NONE,
    updated_at: time::now()
}};""")

# --- hosted_on edges (service -> vm) ---
for svc_name, svc in config["services"].items():
    vm_id = svc.get("vm", "")
    if vm_id in ("all", "local", "") or vm_id not in config["vms"]:
        continue
    if config["vms"][vm_id].get("ip", "TBD") == "TBD":
        continue
    safe_svc = svc_name.replace("-", "_")
    safe_vm = vm_id.replace("-", "_")
    stmts.append(f"RELATE service:{safe_svc}->hosted_on->vm:{safe_vm};")

# --- connected_to edges (WireGuard mesh: all VMs connected to each other) ---
wg_vms = [k.replace("-","_") for k in wg_ips.keys()]
for i, v1 in enumerate(wg_vms):
    for v2 in wg_vms[i+1:]:
        stmts.append(f"RELATE vm:{v1}->connected_to->vm:{v2};")

# --- Known dependency edges ---
# Authelia depends on redis (internal)
stmts.append("RELATE service:authelia->depends_on->service:redis SET type = 'runtime';")
# All proxied services depend on npm (reverse proxy)
proxied = ["authelia", "vaultwarden", "ntfy", "matomo", "photoprism",
           "nocodb", "code_server", "affine", "windmill", "grist",
           "revealmd", "syncthing", "radicale", "flask_api", "mailu"]
for svc in proxied:
    stmts.append(f"RELATE service:{svc}->proxied_by->service:npm;")
# Authelia-protected services
auth_protected = ["vaultwarden", "photoprism", "nocodb", "code_server",
                  "affine", "windmill", "grist", "revealmd", "flask_api"]
for svc in auth_protected:
    stmts.append(f"RELATE service:{svc}->authenticated_by->service:authelia;")
# Backup dependencies
stmts.append("RELATE service:backup_borg->depends_on->service:photoprism SET type = 'data';")
stmts.append("RELATE service:backup_bup->depends_on->service:nocodb SET type = 'data';")
stmts.append("RELATE service:backup_bup->depends_on->service:matomo SET type = 'data';")

print("\n".join(stmts))
PYEOF
)

log "Generated $(echo "$SEED_SQL" | wc -l) SurrealQL statements."

# ---- Execute seed ----
log "Seeding database..."
surreal_query "$SEED_SQL" > /dev/null
log "Seed complete."

# ---- Verify ----
log "Verifying..."
RESULT=$(surreal_query "SELECT count() FROM vm GROUP ALL; SELECT count() FROM service GROUP ALL; SELECT count() FROM hosted_on GROUP ALL; SELECT count() FROM connected_to GROUP ALL; SELECT count() FROM proxied_by GROUP ALL; SELECT count() FROM authenticated_by GROUP ALL; SELECT count() FROM depends_on GROUP ALL;")
echo "$RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
labels = ['VMs', 'Services', 'hosted_on', 'connected_to', 'proxied_by', 'authenticated_by', 'depends_on']
for i, label in enumerate(labels):
    count = data[i]['result'][0]['count'] if data[i]['result'] else 0
    print(f'  {label}: {count}')
" 2>/dev/null || echo "$RESULT"

log "Done. KG seeded from config.json."
