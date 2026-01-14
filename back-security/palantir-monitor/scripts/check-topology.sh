#!/bin/bash
#
# Infrastructure Topology Check
# Shows infrastructure overview in detailed tree format
#

cat << 'EOF'

## 🗺️ Infrastructure Topology

### Cloud Providers

| Provider | Region | Tier |
|----------|--------|------|
| Oracle Cloud (OCI) | eu-marseille-1 | Always Free |
| Google Cloud (GCP) | us-central1 | Free Tier |

### Virtual Machines

| VM | Provider | IP | RAM | Role | Services |
|----|----------|-----|-----|------|----------|
| oci-f-micro_1 | OCI | 130.110.251.193 | 1GB | Mail Server | Mailu |
| oci-f-micro_2 | OCI | 129.151.228.66 | 1GB | Analytics | Matomo |
| gcp-f-micro_1 | GCP | 35.226.147.64 | 1GB | Proxy/Auth | NPM, Authelia, ntfy |
| oci-p-flex_1 | OCI | 84.235.234.87 | 8GB | Media | Photoprism, Syncthing, Radicale |

### Domain Structure

| Domain | Purpose |
|--------|---------|
| diegonmarcos.com | Root domain (Cloudflare DNS) |
| mail.*.com | Email services (Mailu) |
| analytics.*.com | Web analytics (Matomo) |
| proxy.*.com | Reverse proxy admin (NPM) |
| auth.*.com | 2FA gateway (Authelia) |
| rss.*.com | Push notifications (ntfy) |
| photos.app.*.com | Photo management (wake-on-demand) |

### Docker Networks

| Network | Subnet | VM | Purpose |
|---------|--------|----|---------|
| mail_network | 172.20.0.0/24 | oci-f-micro_1 | Mailu stack |
| matomo_network | 172.21.0.0/24 | oci-f-micro_2 | Analytics |
| npm_default | 172.18.0.0/24 | gcp-f-micro_1 | Proxy services |
| dev_network | 172.24.0.0/24 | oci-p-flex_1 | Media apps |

```
┌────────────────────────────────────────────────────────────────────────┐
│                    CLOUD INFRASTRUCTURE TOPOLOGY                        │
└────────────────────────────────────────────────────────────────────────┘

Internet
│
├── Cloudflare DNS (proxy)
│   ├── analytics.diegonmarcos.com → 172.67.168.34
│   ├── proxy.diegonmarcos.com → 172.67.168.34
│   ├── auth.diegonmarcos.com → 104.21.46.63
│   └── cloud.diegonmarcos.com → 104.21.46.63
│
├── OCI eu-marseille-1 ─────────────────────────────────────────┐
│   │                                                             │
│   ├─ [oci-f-micro_1] 130.110.251.193 (1GB)
│   │   Role: Mail Server
│   │   Network: mail_network (172.20.0.0/24)
│   │   Services: Mailu
│   │   Ports: 22, 80, 443, 465, 993, 8080
│   │
│   ├─ [oci-f-micro_2] 129.151.228.66 (1GB)
│   │   Role: Analytics
│   │   Network: matomo_network (172.21.0.0/24)
│   │   Services: Matomo
│   │   Ports: 22, 80, 443
│   │
│   └─ [oci-p-flex_1] 84.235.234.87 (8GB) [SLEEPING]
│       Role: Media (wake-on-demand)
│       Network: dev_network (172.24.0.0/24)
│       Services: Photoprism, Syncthing, Radicale
│       Ports: 22, 80, 443, 5232, 8384
│
└── GCP us-central1 ────────────────────────────────────────────┘
    │
    └─ [gcp-f-micro_1] 35.226.147.64 (1GB)
        Role: Proxy/Auth
        Network: npm_default (172.18.0.0/24)
        Services: NPM, Authelia, ntfy
        Ports: 22, 80, 81, 443

Docker Networks Summary:
• mail_network (172.20.0.0/24) → oci-f-micro_1
• matomo_network (172.21.0.0/24) → oci-f-micro_2
• npm_default (172.18.0.0/24) → gcp-f-micro_1
• dev_network (172.24.0.0/24) → oci-p-flex_1 (sleeping)
```

---

EOF
