#!/bin/bash
# Test all rust-api endpoints and store JSON responses
set -euo pipefail

API="https://api.diegonmarcos.com/rust"
OUT="output-jsons/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

VMS=("oci-p-flex_1" "oci-f-micro_1" "oci-f-micro_2" "gcp-f-micro_1")

# Sample containers per VM (one each for testing)
declare -A VM_CONTAINER
VM_CONTAINER[oci-p-flex_1]="code-server"
VM_CONTAINER[oci-f-micro_2]="matomo-hybrid"
VM_CONTAINER[gcp-f-micro_1]="npm"
VM_CONTAINER[oci-f-micro_1]="mailu-front-1"

# Sample services per VM
declare -A VM_SERVICE
VM_SERVICE[oci-p-flex_1]="photos"
VM_SERVICE[oci-f-micro_2]="analytics"
VM_SERVICE[gcp-f-micro_1]="proxy"
VM_SERVICE[oci-f-micro_1]="mail"

fetch() {
    local method="$1" endpoint="$2" filename="$3"
    local url="${API}${endpoint}"
    printf "%-6s %-60s → " "$method" "$endpoint"
    local http_code
    http_code=$(curl -s -o "$OUT/$filename" -w "%{http_code}" \
        --connect-timeout 10 --max-time 60 \
        -X "$method" "$url" 2>/dev/null || echo "000")
    local size=$(wc -c < "$OUT/$filename" 2>/dev/null || echo 0)
    if [ "$http_code" = "200" ]; then
        printf "\033[32m%s\033[0m (%s bytes)\n" "$http_code" "$size"
    else
        printf "\033[31m%s\033[0m (%s bytes)\n" "$http_code" "$size"
    fi
}

echo "========================================="
echo "  Rust API Endpoint Test"
echo "  $(date)"
echo "  Results: $OUT/"
echo "========================================="
echo

echo "--- Core ---"
fetch GET "/health" "health.json"
fetch GET "/status/all" "status_all.json"
fetch GET "/status/flex1" "status_flex1.json"

echo
echo "--- VM Health (per VM) ---"
for vm in "${VMS[@]}"; do
    fetch GET "/vms/$vm/health" "vm_health_${vm}.json"
done

echo
echo "--- Legacy VM endpoints ---"
fetch GET "/vm/health" "legacy_vm_health.json"

echo
echo "--- Container Status (per VM, read-only) ---"
for vm in "${VMS[@]}"; do
    container="${VM_CONTAINER[$vm]}"
    fetch GET "/vms/$vm/containers/$container/status" "container_status_${vm}_${container}.json"
done

echo
echo "--- Legacy Container Status ---"
fetch GET "/containers/code-server/status" "legacy_container_status.json"

echo
echo "--- Swagger ---"
curl -s --connect-timeout 10 --max-time 15 -o "$OUT/swagger_ui.html" \
    -w "GET    %-60s → %{http_code}\n" "https://api.diegonmarcos.com/rust/swagger-ui/" 2>/dev/null || true

echo
echo "========================================="
echo "  Summary"
echo "========================================="
total=$(ls "$OUT"/*.json 2>/dev/null | wc -l)
ok=$(grep -rl '"status"' "$OUT"/*.json 2>/dev/null | wc -l || echo 0)
echo "Total JSON files: $total"
echo "Results dir: $OUT/"
echo
echo "--- File sizes ---"
ls -lh "$OUT"/ | grep -v ^total
