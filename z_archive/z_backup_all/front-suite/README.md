# Front Suite

Self-hosted productivity suite alternatives to Google/Microsoft services.

## Applications

| App | Folder | Description | Port |
|-----|--------|-------------|------|
| **Docs** | `docs-etherpad` | Collaborative document editor (Google Docs alternative) | 9001 |
| **Sheets** | `sheets-ethercalc` | Spreadsheet editor (Google Sheets alternative) | 8765 |
| **Slides** | `slides-revealjs` | Presentation creator (Google Slides alternative) | 1948 |
| **Notes** | `notes-affine` | Workspace & notes (Notion alternative) | 3010 |
| **Photos** | `photos-photoprism` | AI-powered photo management (Google Photos alternative) | 2342 |
| **Files** | `files-filebrowser` | File manager (Google Drive alternative) | 8080 |
| **PowerSheets** | `powersheets-nocodb` | Database/spreadsheet hybrid (Airtable alternative) | 8080 |
| **LGTM** | `lgtm-grafana` | Observability stack (Logs, Grafana, Traces, Metrics) | 3000 |

## Deployment

Each folder contains a standalone `docker-compose.yml`:

```bash
cd <app-folder>
docker compose up -d
```

## VM Assignment

All suite apps run on **oci-p-flex_1** (Wake-on-Demand):
- IP: 144.24.196.72
- RAM: 8 GB
- Storage: /opt/containers/

## Backup

Suite data is backed up by the backup infrastructure:
- **Code**: Mirrored via Gitea
- **Databases**: SQLite/PostgreSQL dumps via bup (3 AM daily)
- **Media**: Photos/files via Borg deduplication (4 AM daily)
