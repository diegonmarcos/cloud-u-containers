# Matomo Analytics - Management Scripts

Management scripts and utilities for the Matomo analytics server.

---

## 📖 Main Documentation

**See the complete specification**: [`../MATOMO_COMPLETE_SPEC.md`](../MATOMO_COMPLETE_SPEC.md)

This includes:
- Current status and metrics
- Infrastructure setup
- Anti-blocker proxy configuration
- Performance optimizations
- GeoIP geolocation setup
- Tag Manager configuration
- Management commands
- Troubleshooting guide
- Backup procedures

---

## 📂 Directory Structure

```
matomo/
├── README.md                    # This file
├── scripts/                     # Management automation
│   ├── install-matomo.sh        # Initial installation
│   ├── matomo-setup.sh          # Docker setup
│   ├── matomo-login.sh          # Quick SSH access
│   ├── matomo-manage.sh         # Container management
│   ├── matomo-https-setup.sh    # HTTPS configuration (guided)
│   └── matomo-https-auto.sh     # HTTPS configuration (automated)
└── GTM-TN9SV57D.json           # Google Tag Manager export (reference)
```

---

## 🚀 Quick Access

### SSH to Server
```bash
./scripts/matomo-login.sh
# or
ssh -i ~/.ssh/matomo_key ubuntu@130.110.251.193
```

### Container Management
```bash
./scripts/matomo-manage.sh status      # Check status
./scripts/matomo-manage.sh logs        # View logs
./scripts/matomo-manage.sh restart     # Restart services
./scripts/matomo-manage.sh backup      # Create backup
```

---

## 🌐 Access URLs

| Service | URL |
|---------|-----|
| **Matomo Analytics** | https://analytics.diegonmarcos.com |
| **Nginx Proxy Manager** | http://130.110.251.193:81 |
| **Direct Access** | http://130.110.251.193:8080 |

---

## 📊 Server Info

- **IP**: 130.110.251.193
- **Region**: EU-Marseille-1 (France)
- **Instance**: VM.Standard.E2.1.Micro (Always Free)
- **OS**: Ubuntu 24.04 Minimal
- **Resources**: 2 vCPUs, 1GB RAM, 50GB storage

---

## ✅ Current Status

- ✅ Tracking working (95%+ coverage with anti-blocker proxy)
- ✅ GeoIP2 geolocation active (DBIP City Lite)
- ✅ Cron archiving running (hourly)
- ✅ HTTPS/SSL active (Let's Encrypt)
- ✅ Tag Manager published (v6 "Proxy Tracking")

---

**For complete documentation, see**: [`MATOMO_COMPLETE_SPEC.md`](../MATOMO_COMPLETE_SPEC.md)
