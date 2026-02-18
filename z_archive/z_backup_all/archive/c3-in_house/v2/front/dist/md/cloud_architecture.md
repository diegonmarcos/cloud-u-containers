# Cloud Infrastructure Tables

> **Version**: 7.0.0
> **Generated**: 2025-12-23 18:09
> **Source**: `cloud_architecture.json`

This document is auto-generated from `cloud_architecture.json` using `cloud_json_export.py`.
Do not edit manually - changes will be overwritten.

---


## Part I: Overview

### Cloud Providers

| Provider     | Tier        | Region         | Console                                     | CLI          |
| ------------ | ----------- | -------------- | ------------------------------------------- | ------------ |
| Oracle Cloud | always-free | eu-marseille-1 | [Console](https://cloud.oracle.com)         | `OCI CLI`    |
| Google Cloud | free-tier   | us-central1    | [Console](https://console.cloud.google.com) | `gcloud CLI` |

### Active Services Summary

| Service           | URL                                | Availability |
| ----------------- | ---------------------------------- | ------------ |
| Photoprism        | https://photos.diegonmarcos.com    | wake         |
| Matomo Analytics  | https://analytics.diegonmarcos.com | 24/7         |
| Mailu Mail        | https://mail.diegonmarcos.com      | 24/7         |
| Radicale Calendar | https://cal.diegonmarcos.com       | wake         |
| Cloud Dashboard   | https://cloud.diegonmarcos.com     | 24/7         |
| Authelia 2FA      | https://auth.diegonmarcos.com      | 24/7         |

### Central Proxy

**Name**: NPM (Single Central)

**URL**: http://34.55.55.234:81

**VM**: gcp-f-micro_1

## Part II: Infrastructure

### VM Categories

| ID       | Name             | Description                          |
| -------- | ---------------- | ------------------------------------ |
| services | Services         | General purpose VMs for web services |
| ml       | Machine Learning | VMs dedicated to ML workloads        |

### Virtual Machines

| VM ID         | Name             | Provider | Public IP       | RAM  | Storage    | Availability   | Cost    |
| ------------- | ---------------- | -------- | --------------- | ---- | ---------- | -------------- | ------- |
| oci-f-micro_1 | Mail Server      | oracle   | 130.110.251.193 | 1 GB | 47 GB Boot | 24/7           | $0/mo   |
| oci-f-micro_2 | Analytics Server | oracle   | 129.151.228.66  | 1 GB | 47 GB Boot | 24/7           | $0/mo   |
| gcp-f-micro_1 | Central Proxy    | gcloud   | 34.55.55.234    | 1 GB | 30 GB      | 24/7           | $0/mo   |
| oci-p-flex_1  | Dev Server       | oracle   | 84.235.234.87   | 8 GB | 100 GB     | wake-on-demand | $5.5/mo |

### Service Categories

| ID                | Name              | Description                |
| ----------------- | ----------------- | -------------------------- |
| user-productivity | User Productivity | Mail, Calendar, Photos     |
| coder             | Coder Services    | Analytics, Cloud Dashboard |
| infra-proxy       | Proxies           | NPM (SINGLE CENTRAL)       |
| infra-auth        | Authentication    | Authelia 2FA               |
| infra-db          | Databases         | Database services          |
| infra-services    | Infra Services    | APIs and automation        |

### Services Registry

| Service ID | Name                 | Category          | VM            | URL                                 |
| ---------- | -------------------- | ----------------- | ------------- | ----------------------------------- |
| mail       | Mailu Mail Suite     | user-productivity | oci-f-micro_1 | https://mail.diegonmarcos.com/admin |
| photos     | Photoprism           | user-productivity | oci-p-flex_1  | https://photos.diegonmarcos.com     |
| calendar   | Radicale Calendar    | user-productivity | oci-p-flex_1  | https://cal.diegonmarcos.com/.web/  |
| matomo     | Matomo Analytics     | coder             | oci-f-micro_2 | https://analytics.diegonmarcos.com  |
| cloud      | Cloud Dashboard      | coder             | external      | https://cloud.diegonmarcos.com      |
| npm        | NPM (SINGLE CENTRAL) | infra-proxy       | gcp-f-micro_1 | http://34.55.55.234:81              |
| authelia   | Authelia 2FA         | infra-auth        | gcp-f-micro_1 | https://auth.diegonmarcos.com       |
| cache      | Redis Cache          | infra-services    | oci-p-flex_1  |                                     |
| flask-app  | Flask API Server     | infra-services    | gcp-f-micro_1 |                                     |

### Docker Networks

| Network        | VM            | Subnet        | Purpose                 |
| -------------- | ------------- | ------------- | ----------------------- |
| mail_network   | oci-f-micro_1 | 172.20.0.0/24 | Mail services (Mailu)   |
| matomo_network | oci-f-micro_2 | 172.21.0.0/24 | Analytics stack         |
| proxy_network  | gcp-f-micro_1 | 172.23.0.0/24 | NPM + Authelia          |
| dev_network    | oci-p-flex_1  | 172.24.0.0/24 | Photos, Calendar, Cache |

### VM Ports

| VM            | External Ports         | Internal Ports         |
| ------------- | ---------------------- | ---------------------- |
| oci-f-micro_1 | 22, 25, 587, 993, 8080 | -                      |
| oci-f-micro_2 | 22, 80, 443            | 8080, 3306             |
| gcp-f-micro_1 | 22, 80, 443, 81        | 9091, 6379             |
| oci-p-flex_1  | 22, 443                | 5000, 6379, 2342, 5232 |

## Part III: Security

### Domain Configuration

**Primary Domain**: diegonmarcos.com

**Registrar**: Cloudflare

**Nameservers**: burt.ns.cloudflare.com, phoenix.ns.cloudflare.com


### Subdomain Routing

| Domain                     | Service  | VM/Host       | Proxy Via     | Auth     | SSL |
| -------------------------- | -------- | ------------- | ------------- | -------- | --- |
| analytics.diegonmarcos.com | matomo   | oci-f-micro_2 | gcp-f-micro_1 | none     | Yes |
| photos.diegonmarcos.com    | photos   | oci-p-flex_1  | gcp-f-micro_1 | authelia | Yes |
| auth.diegonmarcos.com      | authelia | gcp-f-micro_1 | direct        | none     | Yes |
| mail.diegonmarcos.com      | mail     | oci-f-micro_1 | direct        | native   | Yes |
| cloud.diegonmarcos.com     | cloud    | GitHub Pages  | direct        | none     | Yes |
| cal.diegonmarcos.com       | calendar | oci-p-flex_1  | direct        | authelia | Yes |
| proxy.diegonmarcos.com     | npm      | gcp-f-micro_1 | direct        | authelia | Yes |

### Firewall Rules

| VM            | Port | Protocol | Service         |
| ------------- | ---- | -------- | --------------- |
| oci-f-micro_1 | 22   | TCP      | SSH             |
| oci-f-micro_1 | 587  | TCP      | SMTP Submission |
| oci-f-micro_1 | 993  | TCP      | IMAPS           |
| oci-f-micro_1 | 443  | TCP      | Mailu (HTTPS)   |
| oci-f-micro_2 | 22   | TCP      | SSH             |
| oci-f-micro_2 | 80   | TCP      | HTTP            |
| oci-f-micro_2 | 443  | TCP      | HTTPS           |
| gcp-f-micro_1 | 22   | TCP      | SSH             |
| gcp-f-micro_1 | 80   | TCP      | HTTP            |
| gcp-f-micro_1 | 443  | TCP      | HTTPS           |
| gcp-f-micro_1 | 81   | TCP      | NPM Admin       |
| oci-p-flex_1  | 22   | TCP      | SSH             |
| oci-p-flex_1  | 443  | TCP      | HTTPS           |

### Authentication Methods

| Method       | Description                     | Services                |
| ------------ | ------------------------------- | ----------------------- |
| forward-auth | nginx auth_request via Authelia | photos, calendar, proxy |
| oidc         | OpenID Connect via Authelia     | npm-admin               |
| native       | App-level authentication        | matomo, mail-admin      |


### Authelia OIDC Endpoints

**Issuer**: https://auth.diegonmarcos.com

- **authorization**: `https://auth.diegonmarcos.com/api/oidc/authorization`

- **token**: `https://auth.diegonmarcos.com/api/oidc/token`

- **userinfo**: `https://auth.diegonmarcos.com/api/oidc/userinfo`

## Part IV: Data

### Databases

| Database       | Technology   | Service  | VM            | Storage    |
| -------------- | ------------ | -------- | ------------- | ---------- |
| matomo-db      | MariaDB 11.4 | matomo   | oci-f-micro_2 | 1-10 GB    |
| photos-db      | PostgreSQL   | photos   | oci-p-flex_1  | 1-5 GB     |
| mailu-db       | SQLite       | mail     | oci-f-micro_1 | 100-500 MB |
| authelia-redis | Redis        | authelia | gcp-f-micro_1 | 50-100 MB  |

### Object Storage

| Bucket           | Provider | Size    | Contents              |
| ---------------- | -------- | ------- | --------------------- |
| my-photos        | oracle   | ~248 GB | Google Takeout photos |
| archlinux-images | oracle   | ~2 GB   | Arch Linux VM images  |

### Rclone Remotes

| Remote        | Type                  | Purpose                      |
| ------------- | --------------------- | ---------------------------- |
| gdrive        | Google Drive          | Access Google Drive files    |
| gdrive_photos | Google Photos         | Access Google Photos         |
| oracle_s3     | Oracle Object Storage | S3-compatible bucket storage |

## Part V: Operations

### SSH Commands

| VM            | SSH Command                                                                       |
| ------------- | --------------------------------------------------------------------------------- |
| oci-f-micro_1 | `ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@130.110.251.193` |
| oci-f-micro_2 | `ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@129.151.228.66`  |
| oci-p-flex_1  | `ssh -i ~/Documents/Git/LOCAL_KEYS/00_terminal/ssh/id_rsa ubuntu@84.235.234.87`   |
| gcp-f-micro_1 | `gcloud compute ssh arch-1 --zone us-central1-a`                                  |

### Docker Commands

| Action | Command                                                               |
| ------ | --------------------------------------------------------------------- |
| status | `sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` |
| logs   | `sudo docker logs --tail 100 <container>`                             |
| exec   | `sudo docker exec -it <container> bash`                               |
| stats  | `docker stats --no-stream`                                            |

### Monitoring Commands

| Action      | Command   |
| ----------- | --------- |
| diskUsage   | `df -h`   |
| memoryUsage | `free -h` |
| cpuUsage    | `htop`    |

### Status Legend

| Status | Color  | Description                         |
| ------ | ------ | ----------------------------------- |
| on     | green  | Running and accessible              |
| dev    | blue   | Under active development            |
| wake   | cyan   | Wake-on-Demand (dormant by default) |
| hold   | yellow | Waiting for resources               |
| tbd    | gray   | Planned for future                  |

## Part VI: Reference

### Monthly Costs Summary

**Infrastructure**: $5.5/mo

**AI Services**: $100/mo

**Total**: $105.5/mo USD


### Infrastructure Costs

| Provider     | VM           | Tier        | Cost    |
| ------------ | ------------ | ----------- | ------- |
| oracle       | oci-p-flex_1 | always-free | $5.5/mo |
| gcloud       | -            | free-tier   | $0/mo   |
| cloudflare   | -            | free        | $0/mo   |
| github-pages | -            | free        | $0/mo   |

### Wake-on-Demand Configuration

**Enabled**: Yes

**Target VM**: oci-p-flex_1

**Health Check**: https://photos.diegonmarcos.com

**Idle Timeout**: 1800 seconds

**Services**: photos, calendar, cache


### Port Mapping

| Service        | Internal Port | External Port | Notes             |
| -------------- | ------------- | ------------- | ----------------- |
| npm-gcloud     | 81            | 81            | Admin UI          |
| npm-gcloud     | 80            | 80            | HTTP redirect     |
| npm-gcloud     | 443           | 443           | HTTPS termination |
| matomo-app     | 8080          | 443 (via NPM) | Analytics UI      |
| photoprism-app | 2342          | 443 (via NPM) | Photo gallery     |
| radicale       | 5232          | 443 (via NPM) | Calendar          |
| authelia       | 9091          | internal only | 2FA server        |

### Docker Images

| Service        | Image                     | Version |
| -------------- | ------------------------- | ------- |
| matomo-app     | matomo:fpm-alpine         | latest  |
| matomo-db      | mariadb                   | 11.4    |
| radicale       | tomsquest/docker-radicale | latest  |
| mailu-*        | ghcr.io/mailu/*           | 2024.06 |
| cache-app      | redis                     | alpine  |
| npm-*          | jc21/nginx-proxy-manager  | latest  |
| photoprism-app | photoprism/photoprism     | latest  |
| authelia       | authelia/authelia         | latest  |
