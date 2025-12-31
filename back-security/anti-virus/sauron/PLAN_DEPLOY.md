# Sauron + YARA Deployment Plan

> **Version**: 1.0.0 | **Updated**: 2025-12-23

---

## Overview

Lightweight security monitoring stack for threat detection across all VMs.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         DETECTION LAYER                                  │
│                                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │  oci-micro1 │  │  oci-micro2 │  │  oci-flex1  │  │  gcp-micro1 │     │
│  │             │  │             │  │             │  │             │     │
│  │  Sauron     │  │  Sauron     │  │  Sauron     │  │  Sauron     │     │
│  │  YARA       │  │  YARA       │  │  YARA       │  │  YARA       │     │
│  │  syslog-ng  │  │  syslog-ng  │  │  syslog-ng  │  │  syslog-ng  │     │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘     │
│         │                │                │                │            │
│         └────────────────┴───────┬────────┴────────────────┘            │
│                                  │                                       │
│                                  ▼ TCP :5514                             │
│                       ┌─────────────────────┐                           │
│                       │   CENTRAL (GCP)     │                           │
│                       │   syslog-ng         │                           │
│                       │   SQLite SIEM DB    │                           │
│                       └─────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Sauron (File Integrity Monitor)

Watches filesystem for changes, detects suspicious activity.

| Feature | Description |
|---------|-------------|
| inotify-based | Real-time file change detection |
| Hash verification | SHA256 checksums |
| Output | JSON to syslog |

### 2. YARA (Pattern Matching)

Scans files for malware signatures.

| Feature | Description |
|---------|-------------|
| Rules | Custom + community rules |
| Triggers | On file create/modify (via Sauron) |
| Output | JSON alerts to syslog |

### 3. syslog-ng (Log Transport)

Ships alerts to central server.

| Feature | Description |
|---------|-------------|
| Input | Sauron/YARA JSON |
| Transport | TCP with TLS |
| Output | Central SQLite |

---

## RAM Budget

| Component | RAM | Notes |
|-----------|-----|-------|
| Sauron | ~10 MB | Depends on watch paths |
| YARA | ~20 MB | Depends on rules loaded |
| syslog-ng | ~20 MB | With SQLite plugin |
| **Total per VM** | **~50 MB** | Fits 1GB micro VMs |

---

## Deployment Steps

### Phase 1: Install on each VM

```bash
# Arch-based (GCP)
pacman -S syslog-ng yara

# Ubuntu-based (Oracle)
apt install syslog-ng yara

# Sauron (manual install)
git clone https://github.com/your/sauron
cd sauron && make install
```

### Phase 2: Configure Sauron

```yaml
# /etc/sauron/config.yml
watch_paths:
  - /etc
  - /usr/bin
  - /usr/sbin
  - /home

exclude:
  - /home/*/.cache
  - /var/log

output:
  type: syslog
  facility: local0

yara:
  enabled: true
  rules_dir: /etc/sauron/yara-rules/
  scan_on_change: true
```

### Phase 3: Configure syslog-ng

See: `SYNC_SYSTEM.md`

### Phase 4: Deploy YARA Rules

```bash
# Clone community rules
git clone https://github.com/Yara-Rules/rules /etc/sauron/yara-rules/

# Add custom rules
cat > /etc/sauron/yara-rules/custom/webshell.yar << 'EOF'
rule WebShell {
    strings:
        $s1 = "eval($_POST" nocase
        $s2 = "system($_GET" nocase
        $s3 = "passthru(" nocase
    condition:
        any of them
}
EOF
```

### Phase 5: Enable Services

```bash
systemctl enable --now sauron
systemctl enable --now syslog-ng
```

---

## Directory Structure

```
/etc/sauron/
├── config.yml              # Main config
├── yara-rules/             # YARA rule files
│   ├── malware/
│   ├── webshells/
│   └── custom/
└── whitelist.txt           # False positive exclusions

/var/log/sauron/
├── alerts.jsonl            # Local alert log
└── scan.log                # Scan activity
```

---

## Alert Flow

```
File modified
     │
     ▼
Sauron (inotify)
     │
     ├──► Hash check (integrity)
     │
     └──► YARA scan (malware)
              │
              ▼
         Match found?
         ├── No  → Log change only
         └── Yes → Generate alert
                        │
                        ▼
                   syslog-ng
                        │
                        ├──► Local SQLite (cache)
                        └──► Central TCP:5514
                                  │
                                  ▼
                             Central SIEM
```

---

## References

- Sync System: `./SYNC_SYSTEM.md`
- syslog-ng config: `./config/syslog-ng.conf`
- YARA rules: `./yara-rules/`
