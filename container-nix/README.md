# Container-Nix

Declarative Docker Compose configurations managed via Nix flakes.


## Suite (aa-sui_*)

| Container | Description |
|-----------|-------------|
| `aa-sui_affine` | Self-hosted collaborative workspace (Notion alternative) |
| `aa-sui_code-server` | VS Code in the browser |
| `aa-sui_photoprism` | AI-powered photo management |
| `aa-sui_radicale` | CalDAV/CardDAV server for calendars and contacts |
| `aa-sui_tools-mailu` | Full-featured mail server suite |
| `aa-sui_tools-smtp-proxy` | SMTP relay and filtering proxy |

## Misc (ab-mic_*)

| Container | Description |
|-----------|-------------|
| `ab-mic_syncthing` | Continuous file synchronization |
| `ab-mic_vaultwarden` | Self-hosted Bitwarden password manager |


---


## Cloud Providers (ba-clo_*)

| Container | Description |
|-----------|-------------|
| `ba-clo_cloudflare` | Cloudflare tunnel and DNS management |
| `ba-clo_gcloud` | Google Cloud SDK and tools |
| `ba-clo_oci` | Oracle Cloud Infrastructure CLI |

---

## Security (bb-sec_*)

| Container | Description |
|-----------|-------------|
| `bb-sec_authelia` | SSO and 2FA authentication portal |
| `bb-sec_flask-api` | Custom Flask API for cloud automation |
| `bb-sec_npm` | Nginx Proxy Manager reverse proxy |
| `bb-sec_npm-introspect-proxy` | Token introspection proxy for NPM |
| `bb-sec_wireguard` | VPN server for secure remote access |

## Observability (bc-obs_*)

| Container | Description |
|-----------|-------------|
| `bc-obs_c3-collector` | Metrics and telemetry collector |
| `bc-obs_github-rss` | GitHub releases to RSS feed converter |
| `bc-obs_matomo` | Privacy-focused web analytics |
| `bc-obs_nocodb` | Open-source Airtable alternative |
| `bc-obs_ntfy` | Push notification server |
| `bc-obs_palantir-cron` | Scheduled security monitoring tasks |
| `bc-obs_sauron-lite` | Lightweight log aggregation and alerting |
| `bc-obs_syslog` | Centralized logging server |

---

## Admin (bd-adm_*)

| Container | Description |
|-----------|-------------|

## Data & Backups (ca-dat_*)

| Container | Description |
|-----------|-------------|
| `ca-dat_redis` | In-memory data store for caching |
| `ca-dat_backup-gitea` | Git server for code backup and mirroring |
| `ca-dat_backup-bup` | Database backups (SQLite, MySQL, PostgreSQL) using bup |
| `ca-dat_backup-borg` | Media backups (photos, files) using Borg deduplication |
