#!/bin/bash
# Rust API test script — auto-discovers routes from OpenAPI spec
set -euo pipefail

API="https://api.diegonmarcos.com/rust"
SPEC_URL="${API}/api-docs/openapi.json"
OUT="output-jsons/$(date +%Y%m%d_%H%M%S)"

# Sample values for path parameters
VMS=("oci-p-flex_1" "oci-f-micro_1" "oci-f-micro_2" "gcp-f-micro_1")
declare -A VM_CONTAINER=(
    [oci-p-flex_1]="code-server"
    [oci-f-micro_2]="matomo-hybrid"
    [gcp-f-micro_1]="npm"
    [oci-f-micro_1]="mailu-front-1"
)
declare -A VM_SERVICE=(
    [oci-p-flex_1]="photos"
    [oci-f-micro_2]="analytics"
    [gcp-f-micro_1]="proxy"
    [oci-f-micro_1]="mail"
)

fetch() {
    local method="$1" endpoint="$2" filename="$3"
    local url="${API}${endpoint}"
    printf "%-6s %-60s -> " "$method" "$endpoint"
    local http_code
    http_code=$(curl -s -o "$OUT/$filename" -w "%{http_code}" \
        --connect-timeout 10 --max-time 60 \
        -X "$method" "$url" 2>/dev/null || echo "000")
    local size
    size=$(wc -c < "$OUT/$filename" 2>/dev/null || echo 0)
    if [ "$http_code" = "200" ]; then
        printf "\033[32m%s\033[0m (%s bytes)\n" "$http_code" "$size"
    else
        printf "\033[31m%s\033[0m (%s bytes)\n" "$http_code" "$size"
    fi
}

# Expand a parametrized path into concrete paths
# e.g. /rust/vms/{vm_id}/containers/{name}/status -> one per VM with sample container
expand_path() {
    local path="$1"
    local rust_path="${path#/rust}"  # strip /rust prefix for endpoint

    # No params — return as-is
    if [[ "$path" != *"{"* ]]; then
        local fname
        fname=$(echo "$rust_path" | sed 's|^/||;s|/|_|g').json
        echo "$rust_path|$fname"
        return
    fi

    # Has {vm_id} — expand per VM
    if [[ "$path" == *"{vm_id}"* ]]; then
        for vm in "${VMS[@]}"; do
            local expanded="$rust_path"
            expanded="${expanded//\{vm_id\}/$vm}"
            # Replace {name} with sample container
            if [[ "$expanded" == *"{name}"* ]]; then
                local container="${VM_CONTAINER[$vm]:-unknown}"
                expanded="${expanded//\{name\}/$container}"
            fi
            # Replace {service} with sample service
            if [[ "$expanded" == *"{service}"* ]]; then
                local service="${VM_SERVICE[$vm]:-unknown}"
                expanded="${expanded//\{service\}/$service}"
            fi
            local fname
            fname=$(echo "$expanded" | sed 's|^/||;s|/|_|g').json
            echo "$expanded|$fname"
        done
        return
    fi

    # Legacy routes with {name} or {service} — use flex defaults
    local expanded="$rust_path"
    if [[ "$expanded" == *"{name}"* ]]; then
        expanded="${expanded//\{name\}/code-server}"
    fi
    if [[ "$expanded" == *"{service}"* ]]; then
        expanded="${expanded//\{service\}/photos}"
    fi
    local fname
    fname=$(echo "$expanded" | sed 's|^/||;s|/|_|g').json
    echo "$expanded|$fname"
}

cmd_get_all() {
    mkdir -p "$OUT"

    echo "========================================="
    echo "  Rust API — GET all endpoints"
    echo "  $(date)"
    echo "  Results: $OUT/"
    echo "========================================="
    echo

    # Fetch OpenAPI spec and extract GET routes
    local spec
    spec=$(curl -sL --connect-timeout 10 --max-time 15 "$SPEC_URL" 2>/dev/null)
    if [ -z "$spec" ]; then
        echo "Failed to fetch OpenAPI spec from $SPEC_URL"
        exit 1
    fi

    # Save spec
    echo "$spec" > "$OUT/openapi.json"

    # Parse GET paths grouped by tag
    local routes
    routes=$(echo "$spec" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for path in sorted(data.get('paths', {})):
    methods = data['paths'][path]
    if 'get' in methods:
        tag = methods['get'].get('tags', [''])[0]
        print(f'{tag}|{path}')
")

    local current_tag=""
    while IFS='|' read -r tag path; do
        if [ "$tag" != "$current_tag" ]; then
            echo
            echo "--- $tag ---"
            current_tag="$tag"
        fi

        # Expand parametrized paths and fetch each
        while IFS='|' read -r endpoint fname; do
            fetch GET "$endpoint" "$fname"
        done <<< "$(expand_path "$path")"
    done <<< "$routes"

    echo
    echo "========================================="
    echo "  Summary"
    echo "========================================="
    local total
    total=$(find "$OUT" -name "*.json" ! -name "openapi.json" | wc -l)
    echo "Total JSON files: $total"
    echo "Results dir: $OUT/"
    echo
    echo "--- File sizes ---"
    ls -lhS "$OUT"/ | grep -v ^total
}

usage() {
    echo "Usage: $(basename "$0") <command>"
    echo
    echo "Commands:"
    echo "  get-all    Fetch all GET endpoints (auto-discovered from OpenAPI spec)"
    echo
    echo "API: $API"
    echo "Spec: $SPEC_URL"
}

case "${1:-}" in
    get-all)  cmd_get_all ;;
    *)        usage ;;
esac
