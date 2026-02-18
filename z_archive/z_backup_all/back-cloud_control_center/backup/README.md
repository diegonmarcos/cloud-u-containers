# Backup Infrastructure

Four-tier backup system. `db-agent` runs on ALL VMs, bup/borg/gitea on Flex.

## Components

| Component | Deploy To | Description |
|-----------|-----------|-------------|
| `db-agent/` | ALL VMs | Docker container: auto-detect DBs, dump, log, ntfy notify |
| `bup/` | Flex | SSH server receiving dumps from all VMs via bup |
| `borg/` | Flex | Media backups with content-defined deduplication |
| `gitea/` | Flex | Git mirror server for code repos |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         FLEX VM                                 │
│                    (oci-p-flex_1)                               │
│                     144.24.196.72                               │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. CODE - backup-gitea (:3000, :2222)                   │   │
│  │    Git server mirroring GitHub repos                    │   │
│  │    /backup/code/                                        │   │
│  │    ├── cloud.git                                        │   │
│  │    ├── front.git                                        │   │
│  │    ├── unix.git                                         │   │
│  │    └── vault.git                                        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 2. DATABASES - backup-bup (cron 3 AM)                   │   │
│  │    SQL/SQLite dumps with git-based deduplication        │   │
│  │    /backup/databases/                                   │   │
│  │    └── .bup/                                            │   │
│  │        ├── gcp/        (npm, authelia, vaultwarden)     │   │
│  │        ├── micro1/     (mailu)                          │   │
│  │        ├── micro2/     (matomo)                         │   │
│  │        └── flex/       (nocodb, photoprism)             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 3. MEDIA - backup-borg (cron 4 AM)                      │   │
│  │    Photos, uploads, large files with content dedup      │   │
│  │    /backup/media/borg/                                  │   │
│  │    └── (borg repo)                                      │   │
│  │        ├── photoprism originals                         │   │
│  │        ├── syncthing data                               │   │
│  │        └── radicale calendar                            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
          ▲               ▲               ▲
          │               │               │
    ┌─────┴─────┐   ┌─────┴─────┐   ┌─────┴─────┐
    │    GCP    │   │  Micro 1  │   │  Micro 2  │
    │  SQLite   │   │   Mailu   │   │  Matomo   │
    │   Redis   │   │   Redis   │   │  MariaDB  │
    └───────────┘   └───────────┘   └───────────┘
```

## Tools

| Tier | Tool | Data Type | Dedup Method |
|------|------|-----------|--------------|
| Code | **Gitea** | Git repos | Git packfiles |
| Databases | **bup** | SQL dumps | Git packfiles |
| Media | **Borg** | Binary files | Content-defined chunking |

## Deploy db-agent

```bash
# Deploy to each VM via deploy.sh:
VM_NAME=gcp   ./deploy.sh back-cloud_control_center/backup/db-agent up -d
VM_NAME=flex  ./deploy.sh back-cloud_control_center/backup/db-agent up -d
VM_NAME=micro1 ./deploy.sh back-cloud_control_center/backup/db-agent up -d
VM_NAME=micro2 ./deploy.sh back-cloud_control_center/backup/db-agent up -d

# Or directly with docker compose:
VM_NAME=gcp docker compose -f db-agent/docker-compose.yml up -d
```

### db-agent features
- Auto-detects running DB containers (SQLite, PostgreSQL, MariaDB, Redis)
- Dumps each using native tools (sqlite3 .backup, pg_dump, mysqldump)
- Runs on cron schedule (default: 3 AM daily)
- Logs every job to `/var/log/db-agent/` with timestamps
- Writes `last-run.json` status for monitoring
- Sends ntfy notifications (success/failure)
- Optional bup remote push to Flex
- 7-day local retention, 30-day log retention

## Schedule

| Time | What | Tool |
|------|------|------|
| Continuous | Code mirrors | Gitea (manual/webhook) |
| 3:00 AM | Database dumps | bup |
| 4:00 AM | Media backup | Borg |

## Retention Policy

| Tool | Daily | Weekly | Monthly |
|------|-------|--------|---------|
| bup | 7 | 4 | 6 |
| Borg | 7 | 4 | 6 |

## Usage

### List backups

```bash
# Code (Gitea)
http://144.24.196.72:3000

# Databases (bup)
docker exec backup-bup bup ls

# Media (Borg)
docker exec backup-borg borg list /backup/media/borg
```

### Restore

```bash
# Database
docker exec backup-bup bup restore -C /tmp/restore latest/

# Media
docker exec backup-borg borg extract /backup/media/borg::media-20260205 --path data/photos

# Code
git clone http://144.24.196.72:3000/diego/cloud.git
```

## Storage Estimate

| Type | Size | Dedup Ratio |
|------|------|-------------|
| Code | ~500MB | N/A (already Git) |
| Databases | ~100MB | 80-90% (daily) |
| Media (Photos) | ~50GB | 95%+ (mostly static) |

**Total on Flex: ~5-10GB** (with dedup)
