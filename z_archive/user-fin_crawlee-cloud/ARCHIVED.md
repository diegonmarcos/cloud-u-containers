# ARCHIVED — crawlee-cloud (retired 2026-07-12)

The 7-container self-hosted Apify platform (api/runner/dashboard/scheduler +
Postgres/Redis/MinIO). **Replaced by `a_solutions/user-data_scrappers-api`** — a
lean single-container FastAPI scraper (Instagram / Pinterest / LinkedIn / generic
crawl), on-demand, flat-JSON output.

Retirement:
- Consumers repointed off crawlee (c3-services-mcp `scrappers` tools, discovery
  registry, dashboards, drift test) — commit `18dd3e4bc`.
- Source removed from the active tree, then archived here (source only; the
  regenerable `dist/` and per-container `build-crawlee_*.json` symlinks were
  dropped). Under `z_archive/`, so `2_configs` no longer scans it.
- Migration plan: `a0_tasks/plan_scrappers-api-migration.md`.

The running `crawlee_*` containers + `crawlee_postgres/redis/minio` volumes on
oci-apps are stopped/removed out-of-band (backup first — Apify datasets/KV live
in those volumes). Nothing here is deployed.
