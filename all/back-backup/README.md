# Backup Infrastructure

Three-tier backup system on Flex VM (oci-p-flex_1).

## Nix Flakes

Managed via `container-nix/ca-dat_backup-*`:

| Flake | Service | Description |
|-------|---------|-------------|
| `ca-dat_backup-gitea` | backup-gitea | Git server for code mirroring |
| `ca-dat_backup-bup` | backup-bup | Database backups (SQLite, MySQL, PostgreSQL) |
| `ca-dat_backup-borg` | backup-borg | Media backups with deduplication |

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

## Deploy via Nix

```bash
cd /home/diego/Mounts/Git/cloud/a_solutions/container-nix

# Build individual backup service
nix build .#backup-gitea
nix build .#backup-bup
nix build .#backup-borg

# Deploy to VM
./build.sh deploy backup-gitea
./build.sh deploy backup-bup
./build.sh deploy backup-borg
```

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
