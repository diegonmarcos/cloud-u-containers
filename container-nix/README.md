# Container-Nix

Declarative Docker Compose configurations managed via Nix flakes.


## Containers → Flakes

All running containers across all VMs and their corresponding flake.

### gcp-proxy

| Container | Flake |
|-----------|-------|
| `authelia` | `bb-sec_authelia` |
| `authelia-redis` | `ca-dat_redis` |
| `caddy` | `bb-sec_caddy` |
| `flask-api` | `bb-sec_flask-api` |
| `fluent-bit` | `bc-obs_fluent-bit` |
| `introspect-proxy` | `bb-sec_caddy` |
| `ntfy` | `bc-obs_ntfy` |
| `vaultwarden` | `ab-mic_vaultwarden` |

### oci-flex

| Container | Flake |
|-----------|-------|
| `code-server` | `aa-sui_code-server` |
| `etherpad_app` | `aa-sui_etherpad` |
| `etherpad_postgres` | `aa-sui_etherpad` |
| `filebrowser_app` | `aa-sui_filebrowser` |
| `fluent-bit` | `bc-obs_fluent-bit` |
| `gitea` | `ca-dat_gitea` |
| `grist_app` | `aa-sui_grist` |
| `hedgedoc_app` | `aa-sui_hedgedoc` |
| `hedgedoc_postgres` | `aa-sui_hedgedoc` |
| `lgtm_grafana` | `bc-obs_lgtm` |
| `lgtm_loki` | `bc-obs_lgtm` |
| `lgtm_mimir` | `bc-obs_lgtm` |
| `lgtm_tempo` | `bc-obs_lgtm` |
| `nocodb` | `bc-obs_nocodb` |
| `nocodb_app` | `bc-obs_nocodb` |
| `nocodb-db` | `bc-obs_nocodb` |
| `nocodb_postgres` | `bc-obs_nocodb` |
| `photoprism` | `aa-sui_photoprism` |
| `photoprism_app` | `aa-sui_photoprism` |
| `photoprism-db` | `aa-sui_photoprism` |
| `photoprism_mariadb` | `aa-sui_photoprism` |
| `radicale` | `aa-sui_radicale` |
| `redis` | `ca-dat_redis` |
| `revealmd_app` | `aa-sui_revealmd` |

### oci-mail

| Container | Flake |
|-----------|-------|
| `fluent-bit` | `bc-obs_fluent-bit` |
| `mailu-admin-1` | `aa-sui_tools-mailu` |
| `mailu-antispam-1` | `aa-sui_tools-mailu` |
| `mailu-front-1` | `aa-sui_tools-mailu` |
| `mailu-imap-1` | `aa-sui_tools-mailu` |
| `mailu-redis-1` | `aa-sui_tools-mailu` |
| `mailu-resolver-1` | `aa-sui_tools-mailu` |
| `mailu-smtp-1` | `aa-sui_tools-mailu` |
| `mailu-webmail-1` | `aa-sui_tools-mailu` |
| `matomo-app` | `bc-obs_matomo` |
| `matomo-db` | `bc-obs_matomo` |
| `radicale` | `aa-sui_radicale` |
| `smtp-proxy` | `aa-sui_tools-smtp-proxy` |
| `syncthing` | `ab-mic_syncthing` |
| `syslog-forwarder` | `bc-obs_syslog-forwarder` |

### oci-analytics

| Container | Flake |
|-----------|-------|
| `fluent-bit` | `bc-obs_fluent-bit` |
| `matomo-hybrid` | `bc-obs_matomo` |
| `sauron` | `bb-sec_sauron` |
| `sauron-forwarder` | `bc-obs_sauron-forwarder` |
| `syslog-forwarder` | `bc-obs_syslog-forwarder` |
| `windmill-db` | `bc-obs_windmill` |
| `windmill-server` | `bc-obs_windmill` |
| `windmill-worker` | `bc-obs_windmill` |


## Flakes without a deployed container

| Flake | Category |
|-------|----------|
| `aa-sui_affine` | Collaborative workspace (Notion alternative) |
| `aa-sui_photos-webhook` | Photo sync webhook |
| `ba-clo_cloudflare` | Cloudflare DNS / Terraform |
| `ba-clo_gcloud` | Google Cloud SDK |
| `ba-clo_oci` | Oracle Cloud CLI |
| `bb-sec_mcp-server-skills` | MCP server for Claude |
| `bb-sec_rust-api` | Rust cloud API (replacement for flask-api) |
| `bb-sec_sauron-central` | Central monitoring aggregator |
| `bb-sec_wireguard` | WireGuard VPN mesh (4 VMs) |
| `bc-obs_alerts-api` | Alert routing API |
| `bc-obs_dozzle` | Docker log viewer |
| `bc-obs_sauron-lite` | Lightweight log aggregation |
| `ca-dat_backup-borg` | Media backups (Borg deduplication) |
| `ca-dat_backup-bup` | Database backups (bup) |
| `ca-dat_backup-gitea` | Git backup and mirroring |
| `ca-dat_db-agent` | Database management agent |
| `ca-dat_postlite` | SQLite-based data store |


## Flake categories

### Suite (aa-sui_*)

| Flake | Description |
|-------|-------------|
| `aa-sui_affine` | Self-hosted collaborative workspace (Notion alternative) |
| `aa-sui_code-server` | VS Code in the browser |
| `aa-sui_etherpad` | Real-time collaborative document editor |
| `aa-sui_filebrowser` | Web-based file manager |
| `aa-sui_grist` | Open-source spreadsheet/database |
| `aa-sui_hedgedoc` | Real-time collaborative markdown editor |
| `aa-sui_photoprism` | AI-powered photo management |
| `aa-sui_photos-webhook` | Photo sync webhook |
| `aa-sui_radicale` | CalDAV/CardDAV server for calendars and contacts |
| `aa-sui_revealmd` | Markdown-based presentation server |
| `aa-sui_tools-mailu` | Full-featured mail server suite |
| `aa-sui_tools-smtp-proxy` | SMTP relay and filtering proxy |

### Misc (ab-mic_*)

| Flake | Description |
|-------|-------------|
| `ab-mic_syncthing` | Continuous file synchronization |
| `ab-mic_vaultwarden` | Self-hosted Bitwarden password manager |

### Cloud Providers (ba-clo_*)

| Flake | Description |
|-------|-------------|
| `ba-clo_cloudflare` | Cloudflare DNS Terraform configuration |
| `ba-clo_gcloud` | Google Cloud SDK and tools |
| `ba-clo_oci` | Oracle Cloud Infrastructure CLI |

### Security (bb-sec_*)

| Flake | Description |
|-------|-------------|
| `bb-sec_authelia` | SSO and 2FA authentication portal |
| `bb-sec_caddy` | Caddy reverse proxy + introspect-proxy sidecar (replaces NPM) |
| `bb-sec_flask-api` | Flask API for cloud automation |
| `bb-sec_mcp-server-skills` | MCP server for Claude |
| `bb-sec_rust-api` | Rust cloud API (flask-api replacement) |
| `bb-sec_sauron-central` | Central monitoring aggregator |
| `bb-sec_wireguard` | WireGuard VPN mesh across all 4 VMs |

### Observability (bc-obs_*)

| Flake | Description |
|-------|-------------|
| `bc-obs_alerts-api` | Alert routing API |
| `bc-obs_dozzle` | Docker log viewer |
| `bc-obs_fluent-bit` | Log processor and forwarder |
| `bc-obs_lgtm` | Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) |
| `bc-obs_matomo` | Privacy-focused web analytics |
| `bc-obs_nocodb` | Open-source Airtable alternative |
| `bc-obs_ntfy` | Push notification server |
| `bc-obs_sauron-forwarder` | Alert forwarding to central sauron via netcat |
| `bc-obs_sauron-lite` | Lightweight log aggregation and alerting |
| `bc-obs_syslog-forwarder` | Syslog-ng log forwarding to central server |
| `bc-obs_windmill` | Workflow automation engine |

### Data & Backups (ca-dat_*)

| Flake | Description |
|-------|-------------|
| `ca-dat_backup-borg` | Media backups (Borg deduplication) |
| `ca-dat_backup-bup` | Database backups using bup |
| `ca-dat_backup-gitea` | Git server for code backup and mirroring |
| `ca-dat_db-agent` | Database management agent |
| `ca-dat_gitea` | Self-hosted Git service |
| `ca-dat_postlite` | SQLite-based data store |
| `ca-dat_redis` | In-memory data store for caching |

### Archived (z_archive/)

| Flake | Replaced by |
|-------|-------------|
| `bb-sec_npm` | `bb-sec_caddy` |
| `bb-sec_npm-introspect-proxy-standalone` | `bb-sec_caddy` (introspect-proxy sidecar) |
| `bb-sec_npm-mail` | `bb-sec_caddy` (mail routes via WireGuard) |
| `bb-sec_sauron` | `bc-obs_sauron-lite` / removed |
