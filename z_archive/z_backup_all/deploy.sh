#!/usr/bin/env bash
#
# deploy.sh - Deploy docker services with decrypted secrets
#
# Usage:
#   ./deploy.sh <service-path> [docker-compose-args]
#   ./deploy.sh list                              # List all deployable services
#   ./deploy.sh <service-path> up -d              # Start service
#   ./deploy.sh <service-path> down               # Stop service
#   ./deploy.sh <service-path> logs -f            # View logs
#   ./deploy.sh <service-path> restart            # Restart service
#
# Examples:
#   ./deploy.sh back-security/vault-vaultwarden up -d
#   ./deploy.sh front-suite/photos-photoprism restart
#   ./deploy.sh back-cloud_control_center/windmill logs -f
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup function
cleanup() {
    if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
        rm -f "$ENV_FILE"
    fi
}
trap cleanup EXIT

# List all deployable services (directories with docker-compose.yml)
list_services() {
    echo -e "${BLUE}=== Deployable Services ===${NC}\n"

    while IFS= read -r compose_file; do
        local dir=$(dirname "$compose_file")
        local rel_path="${dir#$SCRIPT_DIR/}"
        local has_secrets=""

        if [[ -f "$dir/secrets.yaml" ]]; then
            has_secrets="${GREEN}[secrets]${NC}"
        fi

        echo -e "  $rel_path $has_secrets"
    done < <(command find "$SCRIPT_DIR" -name "docker-compose.yml" -type f 2>/dev/null | sort)

    echo ""
    echo -e "${BLUE}Usage:${NC} ./deploy.sh <service-path> up -d"
}

# Find docker-compose.yml in service directory
find_compose_file() {
    local service_path="$1"
    local full_path="$SCRIPT_DIR/$service_path"

    if [[ -f "$full_path/docker-compose.yml" ]]; then
        echo "$full_path/docker-compose.yml"
    elif [[ -f "$full_path/docker-compose.yaml" ]]; then
        echo "$full_path/docker-compose.yaml"
    else
        return 1
    fi
}

# Find secrets.yaml in service directory (check current and parent)
find_secrets_file() {
    local service_path="$1"
    local full_path="$SCRIPT_DIR/$service_path"

    # Check in service directory
    if [[ -f "$full_path/secrets.yaml" ]]; then
        echo "$full_path/secrets.yaml"
        return 0
    fi

    # Check in parent directory (for nested services like vault-app inside vault-vaultwarden)
    local parent_path=$(dirname "$full_path")
    if [[ -f "$parent_path/secrets.yaml" ]]; then
        echo "$parent_path/secrets.yaml"
        return 0
    fi

    return 1
}

# Check if secrets file is encrypted
is_encrypted() {
    local file="$1"
    grep -q "^sops:" "$file" 2>/dev/null
}

# Deploy service
deploy_service() {
    local service_path="$1"
    shift
    local compose_args=("$@")

    # Default to 'up -d' if no args provided
    if [[ ${#compose_args[@]} -eq 0 ]]; then
        compose_args=("up" "-d")
    fi

    # Find docker-compose file
    local compose_file
    if ! compose_file=$(find_compose_file "$service_path"); then
        echo -e "${RED}Error: No docker-compose.yml found in $service_path${NC}"
        echo ""
        echo "Available services:"
        list_services
        exit 1
    fi

    local compose_dir=$(dirname "$compose_file")
    local rel_path="${compose_dir#$SCRIPT_DIR/}"

    echo -e "${BLUE}=== Deploying: $rel_path ===${NC}"

    # Check for secrets file
    local secrets_file
    if secrets_file=$(find_secrets_file "$service_path"); then
        local secrets_rel="${secrets_file#$SCRIPT_DIR/}"
        echo -e "Secrets: ${GREEN}$secrets_rel${NC}"

        if ! is_encrypted "$secrets_file"; then
            echo -e "${YELLOW}Warning: secrets.yaml is not encrypted!${NC}"
        fi

        # Create temporary .env file from decrypted secrets
        ENV_FILE="$compose_dir/.env.deploy"

        echo -n "Decrypting secrets... "
        if sops -d "$secrets_file" 2>/dev/null | grep -v '^#' | grep -v '^$' > "$ENV_FILE"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            echo -e "${YELLOW}Proceeding without secrets${NC}"
            rm -f "$ENV_FILE"
            ENV_FILE=""
        fi
    else
        echo -e "Secrets: ${YELLOW}none${NC}"
        ENV_FILE=""
    fi

    # Build docker compose command
    local compose_cmd=("docker" "compose" "-f" "$compose_file")

    if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
        compose_cmd+=("--env-file" "$ENV_FILE")
    fi

    compose_cmd+=("${compose_args[@]}")

    echo -e "Command: ${YELLOW}${compose_args[*]}${NC}"
    echo ""

    # Execute
    cd "$compose_dir"
    "${compose_cmd[@]}"
    local exit_code=$?

    # Cleanup is handled by trap

    if [[ $exit_code -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}Done!${NC}"
    else
        echo ""
        echo -e "${RED}Failed with exit code $exit_code${NC}"
    fi

    return $exit_code
}

# Show usage
usage() {
    echo "Usage: $0 <service-path> [docker-compose-args]"
    echo ""
    echo "Commands:"
    echo "  list                     List all deployable services"
    echo "  <path> up -d             Start service in background"
    echo "  <path> down              Stop service"
    echo "  <path> restart           Restart service"
    echo "  <path> logs -f           Follow logs"
    echo "  <path> ps                Show running containers"
    echo "  <path> pull              Pull latest images"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 back-security/vault-vaultwarden up -d"
    echo "  $0 front-suite/photos-photoprism restart"
    echo "  $0 back-cloud_control_center/windmill logs -f"
    echo ""
    echo "The script automatically:"
    echo "  1. Finds secrets.yaml in the service directory"
    echo "  2. Decrypts it using SOPS/age"
    echo "  3. Passes secrets as environment variables to docker compose"
    echo "  4. Cleans up decrypted files after deployment"
}

# Main
case "${1:-}" in
    "")
        usage
        exit 1
        ;;
    list)
        list_services
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        deploy_service "$@"
        ;;
esac
