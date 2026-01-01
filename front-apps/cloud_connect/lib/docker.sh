#!/usr/bin/env bash
# Cloud Connect - Docker Functions

_DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DOCKER_DIR/common.sh"

# Check if Docker is available
docker_available() {
    has_command docker && docker info &>/dev/null
}

# Require Docker
require_docker() {
    if ! has_command docker; then
        die "Docker is not installed. Install it first."
    fi
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running or you don't have permission. Try: sudo systemctl start docker"
    fi
}

# Check if container exists
container_exists() {
    local name=${1:-$CLOUD_CONTAINER_NAME}
    docker ps -a --format '{{.Names}}' | grep -q "^${name}$"
}

# Check if container is running
container_running() {
    local name=${1:-$CLOUD_CONTAINER_NAME}
    docker ps --format '{{.Names}}' | grep -q "^${name}$"
}

# Get container ID
get_container_id() {
    local name=${1:-$CLOUD_CONTAINER_NAME}
    docker ps -aq --filter "name=^${name}$" | head -1
}

# Check if image exists
image_exists() {
    local image=${1:-$CLOUD_IMAGE_NAME:$CLOUD_IMAGE_TAG}
    docker images -q "$image" | grep -q .
}

# Build image
build_image() {
    local dockerfile=${1:-$CLOUD_MODULES/00-base/Dockerfile}
    local context=${2:-$CLOUD_MODULES/00-base}
    local tag=${3:-$CLOUD_IMAGE_NAME:$CLOUD_IMAGE_TAG}

    log_info "Building image: $tag"
    docker build -t "$tag" -f "$dockerfile" "$context"
}

# Start container
start_container() {
    local name=${1:-$CLOUD_CONTAINER_NAME}

    if container_running "$name"; then
        log_info "Container '$name' is already running"
        return 0
    fi

    if container_exists "$name"; then
        log_info "Starting existing container: $name"
        docker start "$name"
    else
        die "Container '$name' does not exist. Create it first with: ./cloud-connect.sh"
    fi
}

# Stop container
stop_container() {
    local name=${1:-$CLOUD_CONTAINER_NAME}

    if container_running "$name"; then
        log_info "Stopping container: $name"
        docker stop "$name"
    else
        log_info "Container '$name' is not running"
    fi
}

# Remove container
remove_container() {
    local name=${1:-$CLOUD_CONTAINER_NAME}

    if container_exists "$name"; then
        stop_container "$name"
        log_info "Removing container: $name"
        docker rm "$name"
    else
        log_info "Container '$name' does not exist"
    fi
}

# Enter container shell
enter_container() {
    local name=${1:-$CLOUD_CONTAINER_NAME}
    local shell=${2:-/bin/bash}

    if ! container_running "$name"; then
        die "Container '$name' is not running. Start it first."
    fi

    docker exec -it "$name" "$shell"
}

# Execute command in container
exec_in_container() {
    local name=$CLOUD_CONTAINER_NAME

    if ! container_running "$name"; then
        die "Container '$name' is not running. Start it first."
    fi

    docker exec -it "$name" "$@"
}

# Get container logs
container_logs() {
    local name=${1:-$CLOUD_CONTAINER_NAME}
    local lines=${2:-100}

    docker logs --tail "$lines" "$name"
}

# Get container stats
container_stats() {
    local name=${1:-$CLOUD_CONTAINER_NAME}

    docker stats --no-stream "$name"
}

# Export functions
export -f docker_available require_docker
export -f container_exists container_running get_container_id
export -f image_exists build_image
export -f start_container stop_container remove_container
export -f enter_container exec_in_container
export -f container_logs container_stats
