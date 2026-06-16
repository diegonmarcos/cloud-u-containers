# One-Click Cloud Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add one-click deploy buttons (Railway, Render, DigitalOcean) and a VPS deploy script with Caddy auto-HTTPS so users can quickly test Crawlee Cloud.

**Architecture:** PaaS configs deploy API + Dashboard + Scheduler with managed databases (no Runner — needs Docker socket). VPS script deploys the full stack including Runner on any Ubuntu box with Caddy for automatic HTTPS.

**Tech Stack:** Docker Compose, Caddy, Railway/Render/DO config formats, Bash

---

### Task 1: Create VPS Production Docker Compose

**Files:**

- Create: `deploy/vps/docker-compose.prod.yml`

**Step 1: Create the production compose file**

```yaml
# deploy/vps/docker-compose.prod.yml
# Production deployment with Caddy reverse proxy and auto-HTTPS
# Usage: See deploy.sh or deploy/README.md

services:
  # ===========================================
  # REVERSE PROXY
  # ===========================================
  caddy:
    image: caddy:2-alpine
    ports:
      - '80:80'
      - '443:443'
      - '443:443/udp' # HTTP/3
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - api
      - dashboard
    networks:
      - crawlee-network
    restart: unless-stopped

  # ===========================================
  # CORE SERVICES
  # ===========================================
  api:
    build:
      context: ../../
      dockerfile: docker/Dockerfile.api
    environment:
      - NODE_ENV=production
      - PORT=3000
      - DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379
      - S3_ENDPOINT=http://minio:9000
      - S3_ACCESS_KEY=${S3_ACCESS_KEY}
      - S3_SECRET_KEY=${S3_SECRET_KEY}
      - S3_BUCKET=crawlee-cloud
      - S3_REGION=us-east-1
      - S3_FORCE_PATH_STYLE=true
      - API_SECRET=${API_SECRET}
      - CORS_ORIGINS=https://${DOMAIN},https://dashboard.${DOMAIN}
      - RATE_LIMIT_MAX=100
      - LOG_LEVEL=info
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      minio:
        condition: service_healthy
    networks:
      - crawlee-network
    restart: unless-stopped

  runner:
    build:
      context: ../../
      dockerfile: docker/Dockerfile.runner
    environment:
      - NODE_ENV=production
      - API_BASE_URL=http://api:3000
      - API_TOKEN=${API_SECRET}
      - DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379
      - DOCKER_SOCKET=/var/run/docker.sock
      - DOCKER_NETWORK=crawlee-prod_crawlee-network
      - MAX_CONCURRENT_RUNS=${MAX_CONCURRENT_RUNS:-5}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - api
      - redis
      - postgres
    networks:
      - crawlee-network
    restart: unless-stopped

  dashboard:
    build:
      context: ../../
      dockerfile: docker/Dockerfile.dashboard
    environment:
      - NODE_ENV=production
      - PORT=3001
      - NEXT_PUBLIC_API_URL=https://${DOMAIN}
    depends_on:
      - api
    networks:
      - crawlee-network
    restart: unless-stopped

  scheduler:
    build:
      context: ../../
      dockerfile: docker/Dockerfile.api
    command: ['node', 'packages/api/dist/scheduler.js']
    environment:
      - NODE_ENV=production
      - DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379
      - S3_ENDPOINT=http://minio:9000
      - S3_ACCESS_KEY=${S3_ACCESS_KEY}
      - S3_SECRET_KEY=${S3_SECRET_KEY}
      - S3_BUCKET=crawlee-cloud
      - S3_REGION=us-east-1
      - S3_FORCE_PATH_STYLE=true
      - API_SECRET=${API_SECRET}
    depends_on:
      - api
      - redis
    networks:
      - crawlee-network
    restart: unless-stopped

  # ===========================================
  # DATA STORES
  # ===========================================
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${DB_USER}']
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - crawlee-network
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    healthcheck:
      test: ['CMD', 'redis-cli', '-a', '${REDIS_PASSWORD}', 'ping']
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - crawlee-network
    restart: unless-stopped

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${S3_ACCESS_KEY}
      MINIO_ROOT_PASSWORD: ${S3_SECRET_KEY}
    volumes:
      - minio_data:/data
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:9000/minio/health/live']
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - crawlee-network
    restart: unless-stopped

  minio-init:
    image: minio/mc:latest
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set myminio http://minio:9000 $${S3_ACCESS_KEY} $${S3_SECRET_KEY};
      mc mb myminio/crawlee-cloud --ignore-existing;
      exit 0;
      "
    networks:
      - crawlee-network

networks:
  crawlee-network:
    driver: bridge

volumes:
  postgres_data:
  redis_data:
  minio_data:
  caddy_data:
  caddy_config:
```

**Step 2: Commit**

```bash
git add deploy/vps/docker-compose.prod.yml
git commit -m "feat: add production docker-compose with Caddy reverse proxy"
```

---

### Task 2: Create Caddyfile

**Files:**

- Create: `deploy/vps/Caddyfile`

**Step 1: Create the Caddyfile**

```
# Caddyfile for Crawlee Cloud
# Automatic HTTPS via Let's Encrypt
# Domain is set via DOMAIN environment variable

{$DOMAIN} {
	reverse_proxy api:3000
}

dashboard.{$DOMAIN} {
	reverse_proxy dashboard:3001
}
```

**Step 2: Commit**

```bash
git add deploy/vps/Caddyfile
git commit -m "feat: add Caddyfile for auto-HTTPS reverse proxy"
```

---

### Task 3: Create VPS Deploy Script

**Files:**

- Create: `deploy/vps/deploy.sh`

**Step 1: Create the deploy script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Crawlee Cloud - VPS Deploy Script
# Deploys the full platform with Caddy auto-HTTPS on any Ubuntu/Debian VPS
# Usage: bash deploy.sh

REPO_URL="https://github.com/crawlee-cloud/crawlee-cloud.git"
INSTALL_DIR="/opt/crawlee-cloud"

echo "============================================"
echo "  Crawlee Cloud - VPS Deployment"
echo "============================================"
echo ""

# --- Gather user input ---
read -rp "Domain name (e.g. crawlee.example.com): " DOMAIN
read -rp "Admin email: " ADMIN_EMAIL

if [ -z "$DOMAIN" ] || [ -z "$ADMIN_EMAIL" ]; then
  echo "Error: Domain and admin email are required."
  exit 1
fi

# --- Generate secrets ---
echo ""
echo "Generating secrets..."
API_SECRET=$(openssl rand -base64 48 | tr -d '\n/+=')
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n/+=')
DB_USER="crawlee"
DB_NAME="crawlee_cloud"
REDIS_PASSWORD=$(openssl rand -base64 24 | tr -d '\n/+=')
S3_ACCESS_KEY=$(openssl rand -hex 16)
S3_SECRET_KEY=$(openssl rand -base64 32 | tr -d '\n/+=')
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '\n/+=')

# --- Install Docker if needed ---
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

if ! docker compose version &> /dev/null; then
  echo "Error: docker compose plugin not found. Please install Docker Compose V2."
  exit 1
fi

# --- Clone repository ---
echo ""
echo "Setting up Crawlee Cloud in ${INSTALL_DIR}..."
if [ -d "$INSTALL_DIR" ]; then
  echo "Directory ${INSTALL_DIR} already exists. Pulling latest..."
  cd "$INSTALL_DIR"
  git pull
else
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

# --- Write .env file ---
cd deploy/vps

cat > .env << EOF
# Crawlee Cloud Production Configuration
# Generated on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}

# Database
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}

# S3 / MinIO
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}

# API
API_SECRET=${API_SECRET}

# Runner
MAX_CONCURRENT_RUNS=5
EOF

chmod 600 .env

# --- Start services ---
echo ""
echo "Starting Crawlee Cloud..."
docker compose -f docker-compose.prod.yml up -d --build

# --- Wait for services ---
echo ""
echo "Waiting for services to start..."
sleep 10

# --- Print summary ---
echo ""
echo "============================================"
echo "  Crawlee Cloud is starting up!"
echo "============================================"
echo ""
echo "  API:        https://${DOMAIN}"
echo "  Dashboard:  https://dashboard.${DOMAIN}"
echo ""
echo "  Admin email:    ${ADMIN_EMAIL}"
echo "  Admin password: ${ADMIN_PASSWORD}"
echo ""
echo "  MinIO Console:  http://localhost:9001 (internal)"
echo ""
echo "  Install dir:    ${INSTALL_DIR}"
echo "  Config:         ${INSTALL_DIR}/deploy/vps/.env"
echo ""
echo "  IMPORTANT: Save your admin password!"
echo "  DNS: Point ${DOMAIN} and dashboard.${DOMAIN}"
echo "       to this server's IP address."
echo ""
echo "  Logs:  cd ${INSTALL_DIR}/deploy/vps && docker compose -f docker-compose.prod.yml logs -f"
echo "  Stop:  cd ${INSTALL_DIR}/deploy/vps && docker compose -f docker-compose.prod.yml down"
echo "============================================"
```

**Step 2: Make executable and commit**

```bash
chmod +x deploy/vps/deploy.sh
git add deploy/vps/deploy.sh
git commit -m "feat: add VPS deploy script with auto-HTTPS"
```

---

### Task 4: Create Railway Configuration

**Files:**

- Create: `deploy/railway/railway.json`

**Step 1: Create railway.json**

```json
{
  "$schema": "https://railway.app/railway.schema.json",
  "build": {
    "builder": "DOCKERFILE"
  },
  "deploy": {
    "startCommand": "node packages/api/dist/index.js",
    "healthcheckPath": "/v2/health",
    "restartPolicyType": "ON_FAILURE"
  },
  "services": {
    "api": {
      "build": {
        "dockerfilePath": "docker/Dockerfile.api"
      },
      "deploy": {
        "startCommand": "node packages/api/dist/index.js",
        "healthcheckPath": "/v2/health"
      },
      "variables": {
        "NODE_ENV": "production",
        "PORT": "3000",
        "DATABASE_URL": "${{Postgres.DATABASE_URL}}",
        "REDIS_URL": "${{Redis.REDIS_URL}}",
        "S3_ENDPOINT": "http://${{minio.RAILWAY_PRIVATE_DOMAIN}}:9000",
        "S3_ACCESS_KEY": "minioadmin",
        "S3_SECRET_KEY": { "generator": "secret" },
        "S3_BUCKET": "crawlee-cloud",
        "S3_REGION": "us-east-1",
        "S3_FORCE_PATH_STYLE": "true",
        "API_SECRET": { "generator": "secret" },
        "ADMIN_EMAIL": "admin@crawlee.cloud",
        "ADMIN_PASSWORD": { "generator": "secret" },
        "CORS_ORIGINS": "https://${{RAILWAY_PUBLIC_DOMAIN}}"
      }
    },
    "dashboard": {
      "build": {
        "dockerfilePath": "docker/Dockerfile.dashboard"
      },
      "deploy": {
        "startCommand": "node packages/dashboard/server.js"
      },
      "variables": {
        "NODE_ENV": "production",
        "PORT": "3001",
        "NEXT_PUBLIC_API_URL": "https://${{api.RAILWAY_PUBLIC_DOMAIN}}"
      }
    },
    "minio": {
      "image": "minio/minio:latest",
      "deploy": {
        "startCommand": "server /data --console-address :9001"
      },
      "variables": {
        "MINIO_ROOT_USER": "minioadmin",
        "MINIO_ROOT_PASSWORD": "${{api.S3_SECRET_KEY}}"
      }
    }
  }
}
```

**Step 2: Commit**

```bash
git add deploy/railway/railway.json
git commit -m "feat: add Railway one-click deploy configuration"
```

---

### Task 5: Create Render Blueprint

**Files:**

- Create: `deploy/render/render.yaml`

**Step 1: Create render.yaml**

```yaml
# Render Blueprint - Crawlee Cloud
# Deploy: https://render.com/deploy?repo=https://github.com/crawlee-cloud/crawlee-cloud

databases:
  - name: crawlee-db
    plan: starter
    databaseName: crawlee_cloud
    user: crawlee

services:
  - type: web
    name: crawlee-api
    runtime: docker
    dockerfilePath: docker/Dockerfile.api
    dockerContext: .
    plan: starter
    healthCheckPath: /v2/health
    envVars:
      - key: NODE_ENV
        value: production
      - key: PORT
        value: '3000'
      - key: DATABASE_URL
        fromDatabase:
          name: crawlee-db
          property: connectionString
      - key: REDIS_URL
        fromService:
          name: crawlee-redis
          type: redis
          property: connectionString
      - key: S3_ENDPOINT
        fromService:
          name: crawlee-minio
          type: pserv
          envVarKey: MINIO_URL
      - key: S3_ACCESS_KEY
        value: minioadmin
      - key: S3_SECRET_KEY
        generateValue: true
      - key: S3_BUCKET
        value: crawlee-cloud
      - key: S3_REGION
        value: us-east-1
      - key: S3_FORCE_PATH_STYLE
        value: 'true'
      - key: API_SECRET
        generateValue: true
      - key: ADMIN_EMAIL
        value: admin@crawlee.cloud
      - key: ADMIN_PASSWORD
        generateValue: true
      - key: CORS_ORIGINS
        sync: false

  - type: web
    name: crawlee-dashboard
    runtime: docker
    dockerfilePath: docker/Dockerfile.dashboard
    dockerContext: .
    plan: starter
    envVars:
      - key: NODE_ENV
        value: production
      - key: PORT
        value: '3001'
      - key: NEXT_PUBLIC_API_URL
        fromService:
          name: crawlee-api
          type: web
          envVarKey: RENDER_EXTERNAL_URL

  - type: pserv
    name: crawlee-minio
    runtime: docker
    repo: https://hub.docker.com/r/minio/minio
    plan: starter
    disk:
      name: minio-data
      mountPath: /data
      sizeGB: 10
    envVars:
      - key: MINIO_ROOT_USER
        value: minioadmin
      - key: MINIO_ROOT_PASSWORD
        fromService:
          name: crawlee-api
          type: web
          envVarKey: S3_SECRET_KEY
      - key: MINIO_URL
        value: http://crawlee-minio:9000
```

**Step 2: Commit**

```bash
git add deploy/render/render.yaml
git commit -m "feat: add Render blueprint for one-click deploy"
```

---

### Task 6: Create DigitalOcean App Spec

**Files:**

- Create: `deploy/digitalocean/app.yaml`

**Step 1: Create app.yaml**

```yaml
# DigitalOcean App Platform Spec - Crawlee Cloud
# Deploy: https://cloud.digitalocean.com/apps/new?repo=https://github.com/crawlee-cloud/crawlee-cloud

name: crawlee-cloud
region: nyc

services:
  - name: api
    dockerfile_path: docker/Dockerfile.api
    http_port: 3000
    instance_count: 1
    instance_size_slug: basic-s
    health_check:
      http_path: /v2/health
    routes:
      - path: /
    envs:
      - key: NODE_ENV
        value: production
      - key: PORT
        value: '3000'
      - key: DATABASE_URL
        scope: RUN_TIME
        value: ${db.DATABASE_URL}
      - key: REDIS_URL
        scope: RUN_TIME
        value: ${redis.DATABASE_URL}
      - key: S3_ENDPOINT
        value: http://minio:9000
      - key: S3_ACCESS_KEY
        value: minioadmin
      - key: S3_SECRET_KEY
        type: SECRET
        value: REPLACE_ME
      - key: S3_BUCKET
        value: crawlee-cloud
      - key: S3_REGION
        value: us-east-1
      - key: S3_FORCE_PATH_STYLE
        value: 'true'
      - key: API_SECRET
        type: SECRET
        value: REPLACE_ME
      - key: ADMIN_EMAIL
        value: admin@crawlee.cloud
      - key: ADMIN_PASSWORD
        type: SECRET
        value: REPLACE_ME
      - key: CORS_ORIGINS
        value: ${APP_URL}

  - name: dashboard
    dockerfile_path: docker/Dockerfile.dashboard
    http_port: 3001
    instance_count: 1
    instance_size_slug: basic-s
    routes:
      - path: /dashboard
    envs:
      - key: NODE_ENV
        value: production
      - key: PORT
        value: '3001'
      - key: NEXT_PUBLIC_API_URL
        value: ${APP_URL}

databases:
  - engine: PG
    name: db
    version: '16'
    size: db-s-1vcpu-1gb
    num_nodes: 1

  - engine: REDIS
    name: redis
    version: '7'
    size: db-s-1vcpu-1gb
    num_nodes: 1
```

**Step 2: Commit**

```bash
git add deploy/digitalocean/app.yaml
git commit -m "feat: add DigitalOcean App Platform spec"
```

---

### Task 7: Create Deploy README with Badges

**Files:**

- Create: `deploy/README.md`
- Modify: `README.md` (add deploy section after Quick Start)

**Step 1: Create deploy/README.md**

````markdown
# Deploy Crawlee Cloud

Choose your deployment method:

## One-Click Deploy (PaaS)

These deploy API + Dashboard with managed databases. To run Actors, connect a self-hosted Runner (see below).

| Provider     | Deploy                                                                                                                                                                     | Notes                                       |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Railway      | [![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/crawlee-cloud?referralCode=crawlee)                                                    | Includes PostgreSQL + Redis. Easiest setup. |
| Render       | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/crawlee-cloud/crawlee-cloud)                | Free tier available.                        |
| DigitalOcean | [![Deploy to DO](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/crawlee-cloud/crawlee-cloud&refcode=crawlee) | Managed PostgreSQL + Redis.                 |

> **Note:** PaaS deployments don't include the Runner (which needs Docker socket access to execute Actors). See "Connecting a Runner" below.

## Full Stack on VPS

Deploys everything (API + Dashboard + Runner + databases) on a single VPS with automatic HTTPS via Caddy.

### Requirements

- Ubuntu 22.04+ VPS (DigitalOcean Droplet, Hetzner, Linode, etc.)
- A domain name pointed to your server's IP
- Ports 80 and 443 open

### Deploy

SSH into your server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/crawlee-cloud/crawlee-cloud/main/deploy/vps/deploy.sh | bash
```
````

Or clone and run manually:

```bash
git clone https://github.com/crawlee-cloud/crawlee-cloud.git
cd crawlee-cloud
bash deploy/vps/deploy.sh
```

The script will:

1. Prompt for your domain and admin email
2. Install Docker (if needed)
3. Generate all secrets automatically
4. Start all services with Caddy for auto-HTTPS
5. Print your admin credentials and URLs

### DNS Setup

Point these DNS records to your server IP:

- `crawlee.yourdomain.com` (A record) -> API
- `dashboard.crawlee.yourdomain.com` (A record) -> Dashboard

### Management

```bash
cd /opt/crawlee-cloud/deploy/vps

# View logs
docker compose -f docker-compose.prod.yml logs -f

# Restart
docker compose -f docker-compose.prod.yml restart

# Stop
docker compose -f docker-compose.prod.yml down

# Update
cd /opt/crawlee-cloud && git pull
cd deploy/vps && docker compose -f docker-compose.prod.yml up -d --build
```

## Connecting a Runner

If you used a PaaS deployment, you need a separate Runner to execute Actors:

1. Get a VPS with Docker installed
2. Set environment variables:
   ```bash
   export API_BASE_URL=https://your-crawlee-api.railway.app
   export API_TOKEN=your-api-secret
   export DATABASE_URL=your-database-url
   export REDIS_URL=your-redis-url
   ```
3. Run the Runner:
   ```bash
   docker run -d \
     -v /var/run/docker.sock:/var/run/docker.sock \
     -e API_BASE_URL=$API_BASE_URL \
     -e API_TOKEN=$API_TOKEN \
     -e DATABASE_URL=$DATABASE_URL \
     -e REDIS_URL=$REDIS_URL \
     ghcr.io/crawlee-cloud/runner:latest
   ```

````

**Step 2: Add deploy section to root README.md**

Find the line after the Quick Start section closing `---` (around line 100) and add:

```markdown
## Deploy

Deploy your own instance in minutes:

| Method | Description |
|--------|-------------|
| [![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/crawlee-cloud) | One-click deploy with managed databases |
| [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/crawlee-cloud/crawlee-cloud) | Free tier available |
| [![Deploy to DO](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/crawlee-cloud/crawlee-cloud) | DigitalOcean App Platform |
| [VPS Deploy Script](deploy/) | Full stack on any Ubuntu VPS with auto-HTTPS |

See [deploy/](deploy/) for detailed instructions.

---
````

**Step 3: Commit**

```bash
git add deploy/README.md README.md
git commit -m "feat: add deploy documentation with one-click badges"
```

---

### Task 8: Test VPS Compose Locally

**Step 1: Validate compose file syntax**

```bash
cd deploy/vps
# Create a minimal test .env
cat > .env.test << 'EOF'
DOMAIN=localhost
ADMIN_EMAIL=test@test.com
ADMIN_PASSWORD=testpass123
DB_USER=crawlee
DB_PASSWORD=testdbpass
DB_NAME=crawlee_cloud
REDIS_PASSWORD=testredispass
S3_ACCESS_KEY=testaccesskey
S3_SECRET_KEY=testsecretkey
API_SECRET=testsecret123456789012345678901234
MAX_CONCURRENT_RUNS=2
EOF

docker compose -f docker-compose.prod.yml --env-file .env.test config > /dev/null
echo "Compose config is valid"
rm .env.test
```

**Step 2: Commit final state**

```bash
git add -A deploy/
git commit -m "feat: complete one-click deploy for Railway, Render, DigitalOcean, and VPS"
```
