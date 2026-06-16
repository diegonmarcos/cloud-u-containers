# Cloud Infrastructure Documentation

Unified documentation portal for all cloud services deployed across the VM fleet.

## Architecture

```
Cloudflare → Caddy (gcp-proxy) → WireGuard mesh → target VM
```

All services run as Docker containers, configured via Nix flakes. Each service's `config` attrset in `src/flake.nix` is the single source of truth for domains, ports, images, and container names.

## Virtual Machines

| VM | Alias | WG IP | RAM | Role |
|----|-------|-------|-----|------|
| gcp-E2-f_0 | gcp-proxy | 10.0.0.1 | 1 GB | Reverse proxy, auth, DNS |
| oci-E2-f_0 | oci-mail | 10.0.0.3 | 1 GB | Mail, sync, calendar |
| oci-E2-f_1 | oci-analytics | 10.0.0.4 | 1 GB | Analytics, workflows |
| oci-A1-f_0 | oci-apps | 10.0.0.6 | 16 GB | Crawlee, scraping |
| oci-A1-f_1 | oci-apps-1 | 10.0.0.2 | 8 GB | Photos, DB, IDE, AFFiNE |

## Service Categories

- **Applications (aa-sui)** — User-facing tools: photos, mail, calendar, editors
- **Microservices (ab-mic)** — Shared utilities: sync, passwords
- **Financial (ac-fin)** — Trading, scraping, data pipelines
- **AI / AGI (ad-agi)** — LLM inference servers
- **Cloud Providers (ba-clo)** — DNS, Terraform, cloud configs
- **Security (bb-sec)** — Reverse proxy, auth, APIs
- **Observability (bc-obs)** — Logging, monitoring, alerts
- **Data (ca-dat)** — Databases, backups, storage

## How This Portal Works

Each service's `flake.nix` contains a `mkDocs` function that auto-generates an mdBook site from the `config` attrset. The spec page shows all configured values (domains, ports, images, containers). Optional narrative docs in `src/docs/` provide additional context.

Build a service's docs: `cd <service>/src && nix build .#docs`

Build via build.sh: `<service>/build.sh docs`
