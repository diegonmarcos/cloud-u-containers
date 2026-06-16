# One-Click Cloud Deployment - Design Document

Date: 2026-03-06

## Goal

Add quick deployment options so users can easily test Crawlee Cloud on cloud providers. Two deployment modes:

1. **PaaS one-click buttons** (Railway, Render, DigitalOcean) - Deploy API + Dashboard + managed databases. No Runner (needs Docker socket).
2. **VPS deploy script** - Full stack including Runner on any Ubuntu VPS, with Caddy for auto-HTTPS.

## File Structure

```
deploy/
  railway/
    railway.json
  render/
    render.yaml
  digitalocean/
    app.yaml
  vps/
    deploy.sh
    docker-compose.prod.yml
    Caddyfile
  README.md
```

Root README.md updated with deploy badge buttons.

## PaaS Deployments

### Common Pattern

- Deploy API + Dashboard + Scheduler (no Runner)
- Use platform-managed PostgreSQL + Redis
- MinIO container for S3-compatible storage (or platform equivalent)
- Auto-generate API_SECRET at deploy time
- Note in docs: "To run Actors, connect a self-hosted Runner"

### Railway (`railway.json`)

- Defines services: api, dashboard, scheduler, minio
- References existing Dockerfiles
- Provisions PostgreSQL + Redis plugins
- Environment variables reference Railway-provided connection strings

### Render (`render.yaml`)

- Blueprint with web services (api, dashboard) + worker (scheduler) + private service (minio)
- Managed PostgreSQL + Redis instances
- Environment groups for shared config

### DigitalOcean (`app.yaml`)

- App Platform spec with services + managed database components
- PostgreSQL + Redis as managed add-ons

## VPS Deploy Script

### Target

- Ubuntu 22.04+ (DigitalOcean Droplet, Hetzner, any Linux VPS)
- Run directly on the VPS: `curl -fsSL .../deploy.sh | bash`

### Flow

1. Prompt for: domain name, admin email
2. Check/install Docker + Docker Compose
3. Generate all secrets (API_SECRET, DB password, Redis password, S3 keys)
4. Clone repo or download compose + Caddyfile
5. Write .env with generated values
6. Run `docker compose -f docker-compose.prod.yml up -d`
7. Print summary: URLs, admin credentials, next steps

### docker-compose.prod.yml

- All services from docker-compose.yml
- Caddy service (ports 80, 443) for TLS termination
- No internal ports exposed to host (only Caddy faces internet)
- NODE_ENV=production
- Generated secrets (not hardcoded defaults)
- Named volumes for persistence (postgres, redis, minio, caddy certs)

### Caddyfile

- Reverse proxy: `{domain}` -> api:3000
- Reverse proxy: `dashboard.{domain}` or `{domain}:3001` -> dashboard:3001
- Automatic Let's Encrypt HTTPS

## Security Considerations

- All generated secrets use `openssl rand -base64 32`
- Production compose never uses default credentials
- Caddy enforces HTTPS
- Docker socket access limited to runner service only
- .env file created with 600 permissions

## Out of Scope

- Kubernetes / Helm charts (future)
- Fly.io (requires CLI, not one-click)
- Terraform/Pulumi IaC templates (future)
