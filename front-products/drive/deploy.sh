#!/bin/bash
# AFFiNE Deployment Script for Oracle Flex VM
# Uses docker run instead of docker-compose for compatibility

set -e

echo "=== AFFiNE Deployment Starting ==="

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Create volumes if they don't exist
echo "Creating Docker volumes..."
docker volume create affine_config 2>/dev/null || true
docker volume create affine_storage 2>/dev/null || true
docker volume create redis_data 2>/dev/null || true
docker volume create postgres_data 2>/dev/null || true

# Ensure network exists
echo "Ensuring dev_network exists..."
docker network inspect dev_network >/dev/null 2>&1 || docker network create dev_network --subnet 172.24.0.0/24

# Stop and remove existing containers if they exist
echo "Cleaning up existing containers..."
docker stop affine_postgres affine_redis affine_app 2>/dev/null || true
docker rm affine_postgres affine_redis affine_app 2>/dev/null || true

# Start PostgreSQL
echo "Starting PostgreSQL..."
docker run -d \
  --name affine_postgres \
  --network dev_network \
  --restart unless-stopped \
  -e POSTGRES_USER=affine \
  -e POSTGRES_PASSWORD=affine \
  -e POSTGRES_DB=affine \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v postgres_data:/var/lib/postgresql/data \
  --health-cmd='pg_isready -U affine' \
  --health-interval=10s \
  --health-timeout=5s \
  --health-retries=5 \
  postgres:16-alpine

# Wait for PostgreSQL to be healthy
echo "Waiting for PostgreSQL to be ready..."
until docker exec affine_postgres pg_isready -U affine >/dev/null 2>&1; do
  echo -n "."
  sleep 2
done
echo " PostgreSQL is ready!"

# Start Redis
echo "Starting Redis..."
docker run -d \
  --name affine_redis \
  --network dev_network \
  --restart unless-stopped \
  -v redis_data:/data \
  --health-cmd='redis-cli ping' \
  --health-interval=10s \
  --health-timeout=5s \
  --health-retries=5 \
  redis:7-alpine redis-server --save 60 1 --loglevel warning

# Wait for Redis to be healthy
echo "Waiting for Redis to be ready..."
until docker exec affine_redis redis-cli ping >/dev/null 2>&1; do
  echo -n "."
  sleep 1
done
echo " Redis is ready!"

# Start AFFiNE
echo "Starting AFFiNE application..."
docker run -d \
  --name affine_app \
  --network dev_network \
  --restart unless-stopped \
  -p 3010:3010 \
  -e AFFINE_CONFIG_PATH=/root/.affine/config \
  -e REDIS_SERVER_HOST=affine_redis \
  -e DATABASE_URL=postgres://affine:affine@affine_postgres:5432/affine \
  -e NODE_ENV=production \
  -e AFFINE_ADMIN_EMAIL=${AFFINE_ADMIN_EMAIL:-admin@diegonmarcos.com} \
  -e AFFINE_ADMIN_PASSWORD=${AFFINE_ADMIN_PASSWORD:-changeme} \
  -e AFFINE_SERVER_HOST=0.0.0.0 \
  -e AFFINE_SERVER_PORT=3010 \
  -e AFFINE_SERVER_HTTPS=false \
  -e ENABLE_CAPTCHA=false \
  -e THROTTLE_TTL=60 \
  -e THROTTLE_LIMIT=120 \
  -e AFFINE_STORAGE_PROVIDER=fs \
  -e AFFINE_STORAGE_PATH=/root/.affine/storage \
  -v affine_config:/root/.affine/config \
  -v affine_storage:/root/.affine/storage \
  ghcr.io/toeverything/affine-graphql:stable

echo ""
echo "=== Deployment Complete! ==="
echo ""
echo "Container Status:"
docker ps --filter name=affine --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "To view logs:"
echo "  docker logs -f affine_app"
echo "  docker logs -f affine_postgres"
echo "  docker logs -f affine_redis"
echo ""
echo "Access AFFiNE at: http://84.235.234.87:3010"
echo "Or via domain (after NPM config): https://drive.diegonmarcos.com"
echo ""
