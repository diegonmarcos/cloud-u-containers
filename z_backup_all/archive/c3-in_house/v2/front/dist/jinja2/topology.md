
# Topology

> Generated: 2025-12-23 19:05

---

## Virtual Machines

| Host | VM ID | IP | Docker Network | OS |
|------|-------|-----|----------------|-----|
| GCP | gcp-f-micro_1 | `34.55.55.234` | proxy_network | Arch Linux |
| OCI | oci-p-flex_1 | `84.235.234.87` | dev_network | Ubuntu 24.04 |
| OCI | oci-f-micro_1 | `130.110.251.193` | mail_network | Ubuntu 24.04 |
| OCI | oci-f-micro_2 | `129.151.228.66` | matomo_network | Ubuntu 24.04 |


---

## Services by VM


### gcp-f-micro_1

| Service | Description | Ports | Status |
|---------|-------------|-------|--------|
| **NPM** | Nginx Proxy Manager | `80, 443, 81` | Active |
| **Authelia** | 2FA Authentication | `9091` | Active |
| **Cloud API** | Flask API Server | `5000` | Active |



### oci-p-flex_1

| Service | Description | Ports | Status |
|---------|-------------|-------|--------|
| **PhotoPrism** | Photo Gallery | `2342` | Wake-on-Demand |
| **Radicale** | Calendar/Contacts | `5232` | Wake-on-Demand |
| **WireGuard** | VPN Server | `51820/udp` | Active |
| **Redis** | Cache Server | `-` | Active |



### oci-f-micro_1

| Service | Description | Ports | Status |
|---------|-------------|-------|--------|
| **Mailu** | Mail Suite | `25, 465, 587, 993, 995` | Active |



### oci-f-micro_2

| Service | Description | Ports | Status |
|---------|-------------|-------|--------|
| **Matomo** | Web Analytics | `8080` | Active |




---

## Database Allocations


### gcp-f-micro_1 (10 GB Boot)

| Database | Type | Service | Size | Path |
|----------|------|---------|------|------|
| **authelia-db** | SQLite | Authelia | ~5 MB | `/data/authelia/db.sqlite3` |
| **npm-db** | SQLite | NPM | ~10 MB | `/data/npm/database.sqlite` |



### oci-p-flex_1 (242 GB Boot)

| Database | Type | Service | Size | Path |
|----------|------|---------|------|------|
| **photoprism-db** | MariaDB | PhotoPrism | ~2 GB | `/data/photoprism/database/` |
| **photoprism-sidecar** | Files (YAML/JSON) | PhotoPrism | ~5 GB | `/data/photoprism/storage/sidecar/` |
| **photoprism-originals** | Files (Photos) | PhotoPrism | ~100 GB | `/data/photoprism/originals/` |
| **radicale-db** | Files (ICS/VCF) | Radicale | ~50 MB | `/data/radicale/collections/` |



### oci-f-micro_1 (47 GB Boot)

| Database | Type | Service | Size | Path |
|----------|------|---------|------|------|
| **mailu-db** | SQLite | Mailu | ~50 MB | `/mailu/data/main.db` |
| **mailu-mail** | Maildir | Mailu (Dovecot) | ~2 GB | `/mailu/mail/` |
| **mailu-dkim** | Keys | Mailu (DKIM) | ~1 MB | `/mailu/dkim/` |



### oci-f-micro_2 (47 GB Boot)

| Database | Type | Service | Size | Path |
|----------|------|---------|------|------|
| **matomo-db** | MariaDB | Matomo | ~1 GB | `/data/matomo/db/` |
| **matomo-config** | PHP Files | Matomo | ~50 MB | `/data/matomo/config/` |




---

## Docker Containers


### gcp-f-micro_1 (3 containers)

| Container | Image | Ports | Network | Status |
|-----------|-------|-------|---------|--------|
| **npm** | `jc21/nginx-proxy-manager:latest` | `80, 443, 81` | proxy_network | UP |
| **authelia** | `authelia/authelia:latest` | `9091` | proxy_network | UP |
| **cloud-api** | `python:3.11-slim` | `5000` | proxy_network | UP |



### oci-p-flex_1 (6 containers)

| Container | Image | Ports | Network | Status |
|-----------|-------|-------|---------|--------|
| **photoprism** | `photoprism/photoprism:latest` | `127.0.0.1:2342` | dev_network | UP |
| **photoprism-db** | `mariadb:10.11` | `-` | dev_network | UP |
| **radicale** | `tomsquest/docker-radicale:latest` | `127.0.0.1:5232` | dev_network | UP |
| **wireguard** | `linuxserver/wireguard:latest` | `51820/udp` | host | UP |
| **redis** | `redis:alpine` | `-` | dev_network | UP |



### oci-f-micro_1 (8 containers)

| Container | Image | Ports | Network | Status |
|-----------|-------|-------|---------|--------|
| **mailu-front** | `mailu/nginx:2.0` | `25, 465, 587, 993, 995, 143` | mail_network | UP |
| **mailu-admin** | `mailu/admin:2.0` | `-` | mail_network | UP |
| **mailu-imap** | `mailu/dovecot:2.0` | `-` | mail_network | UP |
| **mailu-smtp** | `mailu/postfix:2.0` | `-` | mail_network | UP |
| **mailu-antispam** | `mailu/rspamd:2.0` | `-` | mail_network | UP |
| **mailu-webmail** | `mailu/webmail:2.0` | `-` | mail_network | UP |
| **mailu-redis** | `redis:alpine` | `-` | mail_network | UP |
| **mailu-resolver** | `mailu/unbound:2.0` | `-` | mail_network | UP |



### oci-f-micro_2 (2 containers)

| Container | Image | Ports | Network | Status |
|-----------|-------|-------|---------|--------|
| **matomo** | `matomo:fpm-alpine` | `127.0.0.1:8080` | matomo_network | UP |
| **matomo-db** | `mariadb:10.11` | `-` | matomo_network | UP |




---

## Docker Networks

| Network | VM | Subnet | Purpose |
|---------|-----|--------|---------|
| **proxy_network** | gcp-f-micro_1 | `172.23.0.0/24` | NPM + Authelia |
| **dev_network** | oci-p-flex_1 | `172.24.0.0/24` | Photos, Calendar, Cache |
| **mail_network** | oci-f-micro_1 | `172.20.0.0/24` | Mailu Mail |
| **matomo_network** | oci-f-micro_2 | `172.21.0.0/24` | Analytics |


---

## Storage Summary

| Metric | Value |
|--------|-------|
| Total Data | ~190 GB |
| MariaDB/SQLite DBs | 4 |
| File Storage | ~180 GB |
| Total Disk Capacity | 346 GB |
