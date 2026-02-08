#!/bin/bash

# Introspect Proxy Build Script
# Deploys to gcp-f-micro_1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

case "${1:-help}" in
    build)
        echo "Building introspect-proxy image..."
        docker compose build
        ;;
    up)
        echo "Starting introspect-proxy..."
        docker compose up -d
        ;;
    down)
        echo "Stopping introspect-proxy..."
        docker compose down
        ;;
    logs)
        docker compose logs -f
        ;;
    restart)
        docker compose restart
        ;;
    test)
        echo "Testing introspection endpoint..."
        # Test health
        curl -s http://localhost:4182/health && echo " - Health OK"

        # Test without token (should 401)
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:4182/auth)
        if [ "$STATUS" = "401" ]; then
            echo "No-token test: 401 - OK"
        else
            echo "No-token test: $STATUS - FAIL (expected 401)"
        fi
        ;;
    deploy)
        echo "Deploying to gcp-f-micro_1..."
        # Copy files to server
        gcloud compute scp --zone us-central1-a --recurse \
            "$PROJECT_DIR" arch-1:/tmp/introspect-proxy

        # Build and run on server
        gcloud compute ssh arch-1 --zone us-central1-a --command "
            cd /tmp/introspect-proxy
            docker compose build
            docker compose up -d
            docker compose logs --tail 10
        "
        ;;
    *)
        echo "Usage: $0 {build|up|down|logs|restart|test|deploy}"
        echo ""
        echo "Commands:"
        echo "  build   - Build Docker image"
        echo "  up      - Start container"
        echo "  down    - Stop container"
        echo "  logs    - Follow logs"
        echo "  restart - Restart container"
        echo "  test    - Test endpoints locally"
        echo "  deploy  - Deploy to gcp-f-micro_1"
        ;;
esac
