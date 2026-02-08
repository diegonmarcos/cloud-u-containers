#!/usr/bin/env bash
# Cloud Connect - Common Functions

set -euo pipefail

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_COMMON_DIR/colors.sh"
source "$_COMMON_DIR/logging.sh"

# Project paths
export CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$_COMMON_DIR/.." && pwd)}"
export CLOUD_MODULES="$CLOUD_ROOT/modules"
export CLOUD_CONFIGS="$CLOUD_ROOT/configs"
export CLOUD_LIB="$CLOUD_ROOT/lib"

# Container settings
export CLOUD_CONTAINER_NAME="${CLOUD_CONTAINER_NAME:-cloud-connect}"
export CLOUD_IMAGE_NAME="${CLOUD_IMAGE_NAME:-cloud-connect}"
export CLOUD_IMAGE_TAG="${CLOUD_IMAGE_TAG:-latest}"

# Check if running inside container
in_container() {
    [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null || [[ -n "${CLOUD_IN_CONTAINER:-}" ]]
}

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Require root
require_root() {
    if ! is_root; then
        die "This command must be run as root (use sudo)"
    fi
}

# Require container
require_container() {
    if ! in_container; then
        die "This command must be run inside the container"
    fi
}

# Require host (not in container)
require_host() {
    if in_container; then
        die "This command must be run on the host, not inside the container"
    fi
}

# Check if command exists
has_command() {
    command -v "$1" &>/dev/null
}

# Require command
require_command() {
    local cmd=$1
    local package=${2:-$1}
    if ! has_command "$cmd"; then
        die "Required command '$cmd' not found. Install it with: pacman -S $package"
    fi
}

# Calculate 90% of system resources
get_cpu_limit() {
    local total_cpus
    total_cpus=$(nproc)
    echo "scale=1; $total_cpus * 0.9" | bc
}

get_mem_limit() {
    local total_mem
    total_mem=$(free -g | awk '/Mem:/ {print $2}')
    # Minimum 2GB, 90% of total
    local limit
    limit=$(echo "scale=0; $total_mem * 9 / 10" | bc)
    if [[ $limit -lt 2 ]]; then
        limit=2
    fi
    echo "${limit}g"
}

get_swap_limit() {
    local mem_limit
    mem_limit=$(get_mem_limit)
    # Swap = 2x RAM limit
    local mem_num=${mem_limit%g}
    echo "$((mem_num * 2))g"
}

# Wait for condition with timeout
wait_for() {
    local condition=$1
    local timeout=${2:-30}
    local interval=${3:-1}
    local elapsed=0

    while ! eval "$condition" 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 0
}

# Confirm action
confirm() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n] "
    else
        prompt="$prompt [y/N] "
    fi

    read -rp "$prompt" response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

# Get vault path (if loaded)
get_vault_path() {
    if [[ -f /vault/.vault ]]; then
        cat /vault/.vault
    else
        echo ""
    fi
}

# Check if vault is loaded
vault_loaded() {
    [[ -d /vault ]] && [[ -f /vault/.vault ]]
}

# Require vault
require_vault() {
    if ! vault_loaded; then
        die "This command requires a vault. Load one with: cloud vault load /path/to/vault"
    fi
}

# Export functions
export -f in_container is_root require_root require_container require_host
export -f has_command require_command
export -f get_cpu_limit get_mem_limit get_swap_limit
export -f wait_for confirm
export -f get_vault_path vault_loaded require_vault
