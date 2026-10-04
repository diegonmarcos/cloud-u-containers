#!/bin/bash
#
# Cloud Control API - Build & Sync Script
#
# Usage:
#   ./build.sh              # Show help
#   ./build.sh generate     # Generate .js files from cloud_dash.json
#   ./build.sh sync         # Sync dist/ to front-end api/src/
#   ./build.sh build        # Generate + sync (full build)
#   ./build.sh clean        # Remove generated files
#
# Author: Diego Nepomuceno Marcos
# Last Updated: 2025-12-14

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$API_ROOT/src"
DIST_DIR="$API_ROOT/dist"
FLASK_DIR="$API_ROOT/flask-app"

# Front-end target
FRONTEND_API_SRC="/home/diego/Documents/Git/front-Github_io/a_Cloud/api/src"

# Source config
CLOUD_CONFIG="/home/diego/Documents/Git/back-System/cloud/1.ops/cloud_dash.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}  Cloud Control API - Build Script${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

show_help() {
    print_header
    echo "Usage: ./build.sh [command]"
    echo ""
    echo "Commands:"
    echo "  generate    Generate .js files from cloud_dash.json to dist/"
    echo "  sync        Sync dist/ files to front-end api/src/"
    echo "  build       Generate + sync (full build)"
    echo "  clean       Remove generated files from dist/"
    echo "  status      Show current file status"
    echo "  help        Show this help message"
    echo ""
    echo "Paths:"
    echo "  Source:     $SRC_DIR"
    echo "  Dist:       $DIST_DIR"
    echo "  Frontend:   $FRONTEND_API_SRC"
    echo "  Config:     $CLOUD_CONFIG"
    echo ""
}

# =============================================================================
# COMMANDS
# =============================================================================

cmd_generate() {
    print_info "Generating .js files from cloud_dash.json..."

    if [[ ! -f "$SRC_DIR/export_cloud_control_data.py" ]]; then
        print_error "Export script not found: $SRC_DIR/export_cloud_control_data.py"
        exit 1
    fi

    if [[ ! -f "$CLOUD_CONFIG" ]]; then
        print_error "Config not found: $CLOUD_CONFIG"
        exit 1
    fi

    # Run export script with dist/ as output
    cd "$SRC_DIR"
    python3 export_cloud_control_data.py --output-dir "$DIST_DIR"

    print_success "Generated files in $DIST_DIR"
    ls -la "$DIST_DIR"/*.js 2>/dev/null | awk '{print "  " $NF}'
}

cmd_sync() {
    print_info "Syncing dist/ to front-end api/src/..."

    if [[ ! -d "$DIST_DIR" ]]; then
        print_error "Dist directory not found: $DIST_DIR"
        exit 1
    fi

    if [[ ! -d "$FRONTEND_API_SRC" ]]; then
        print_error "Frontend api/src not found: $FRONTEND_API_SRC"
        exit 1
    fi

    # Sync .js files
    for file in "$DIST_DIR"/*.js; do
        if [[ -f "$file" ]]; then
            filename=$(basename "$file")
            cp "$file" "$FRONTEND_API_SRC/$filename"
            print_success "Synced $filename"
        fi
    done

    # Sync openapi files
    if [[ -f "$DIST_DIR/openapi.json" ]]; then
        cp "$DIST_DIR/openapi.json" "$FRONTEND_API_SRC/"
        print_success "Synced openapi.json"
    fi

    if [[ -f "$SRC_DIR/openapi.yaml" ]]; then
        cp "$SRC_DIR/openapi.yaml" "$FRONTEND_API_SRC/"
        print_success "Synced openapi.yaml"
    fi

    print_success "Sync complete to $FRONTEND_API_SRC"
}

cmd_build() {
    print_header
    cmd_generate
    echo ""
    cmd_sync
    echo ""
    print_success "Build complete!"
}

cmd_clean() {
    print_info "Cleaning generated files..."

    rm -f "$DIST_DIR"/*.js
    rm -f "$DIST_DIR"/*.json

    print_success "Cleaned $DIST_DIR"
}

cmd_status() {
    print_header

    echo "Source files (src/):"
    ls -la "$SRC_DIR" 2>/dev/null | tail -n +4 | awk '{print "  " $NF " (" $5 " bytes)"}'
    echo ""

    echo "Generated files (dist/):"
    ls -la "$DIST_DIR" 2>/dev/null | tail -n +4 | awk '{print "  " $NF " (" $5 " bytes)"}'
    echo ""

    echo "Frontend files (api/src/):"
    ls -la "$FRONTEND_API_SRC" 2>/dev/null | tail -n +4 | awk '{print "  " $NF " (" $5 " bytes)"}'
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-help}" in
    generate)
        cmd_generate
        ;;
    sync)
        cmd_sync
        ;;
    build)
        cmd_build
        ;;
    clean)
        cmd_clean
        ;;
    status)
        cmd_status
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        print_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
