# Crawlee Cloud Roadmap

A CLI-first platform for running large-scale scrapers on your own infrastructure.

## Current Version: v0.5.0 ✅

- Apify-compatible REST API
- Docker-based Actor execution
- CLI for deployment (`crc push`, `crc run`, `crc logs`)
- Datasets, Key-Value Stores, Request Queues
- Basic web dashboard

---

## v0.2.0 - CLI & Developer Experience

Priority: Make the CLI the best way to work with Crawlee Cloud.

- [x] **Improved CLI output** - Better formatting, colors, progress bars
- [x] **`crc init`** - Scaffold new Actor projects from templates
- [x] **`crc dev`** - Local development mode with hot reload
- [x] **`crc status`** - Check run status and resource usage
- [x] **Input schema validation** - Validate inputs before running
- [x] **Better error messages** - Actionable hints for common issues

## v0.3.0 - Production Scraping at Scale ✅

Priority: Run large scraping jobs reliably.

- [x] **Cron scheduling** - Schedule runs with cron expressions
- [x] **Retry policies** - Automatic retries with configurable backoff
- [x] **Run timeouts** - Kill stuck runs automatically
- [x] **Webhooks** - HTTP callbacks on run completion with delivery tracking and exponential backoff retry
- [x] **Multi-worker runners** - Scale horizontally for parallel execution
- [x] **Resource limits** - Memory/CPU caps per run

## v0.4.0 - Reliability & Operations ✅

Priority: Production-grade stability.

- [x] **Metrics & monitoring** - Prometheus endpoints (`GET /metrics` with prom-client)
- [x] **Health checks** - Liveness (`/health/live`) and readiness (`/health/ready`) probes with DB, Redis, S3 checks
- [x] **Graceful shutdown** - API server drains requests, runner waits for active containers (configurable timeout)
- [x] **Run history retention** - CLI cleanup script with `--dry-run`, S3 + DB cleanup
- [x] **Backup & restore** - `pg_dump`/`pg_restore` wrapper scripts

## v0.5.0 - Security & Polish ✅

Priority: Secure the platform and prepare for wider use.

- [x] **One-click cloud deploy** - Deploy buttons for Railway, Render, DigitalOcean + VPS script with Caddy auto-HTTPS
- [x] **Authentication middleware** - All API routes require authentication via preHandler hook
- [x] **User-scoped resources** - Datasets, KV stores, request queues, and actors are scoped per user
- [x] **Input validation** - Zod schemas for all route inputs (datasets, KV stores, request queues, runs)
- [x] **SSRF protection** - Block webhook delivery to private/internal network addresses (RFC 1918, loopback, link-local)
- [x] **Runner API key from Redis** - Runner fetches API key from Redis instead of static config
- [x] **Security config validation** - Startup checks for weak secrets, insecure DB/S3 credentials, CORS
- [ ] Actor versioning - Deploy and rollback specific versions
- [ ] API key scopes - Read-only vs full access keys
- [ ] Improved dashboard - Better UX for those who prefer UI
- [ ] Documentation improvements

---

## Non-Goals (for now)

To keep focus, these are explicitly **not** on the roadmap:

- ❌ Web IDE for editing Actors
- ❌ Multi-tenant workspaces
- ❌ Complex RBAC/permissions
- ❌ Built-in proxy rotation (use your own)

---

## Contributing

Have ideas? Open an issue on GitHub!

The best contributions are CLI improvements, bug fixes, and documentation.
