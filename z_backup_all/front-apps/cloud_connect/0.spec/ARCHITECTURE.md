# Cloud Connect - Architecture

> **Document Type**: System Structure & Components
> **Version**: 2.0
> **Last Updated**: 2026-01-01

---

## 1. System Overview

### 1.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HOST SYSTEM                                     │
│  (Linux + Docker + Shell)                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   cloud-connect.sh                                                           │
│         │                                                                    │
│         ▼                                                                    │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     DOCKER CONTAINER                                 │   │
│   │                     (Arch Linux)                                     │   │
│   │                                                                      │   │
│   │   ┌───────────────────────────────────────────────────────────────┐ │   │
│   │   │                      MODULES                                   │ │   │
│   │   │                                                                │ │   │
│   │   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐         │ │   │
│   │   │  │ 00-base  │ │ 01-tools │ │02-desktop│ │ 03-vault │         │ │   │
│   │   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘         │ │   │
│   │   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐         │ │   │
│   │   │  │  04-vpn  │ │  05-ssh  │ │ 06-mount │ │07-config │         │ │   │
│   │   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘         │ │   │
│   │   │  ┌──────────┐ ┌──────────┐                                   │ │   │
│   │   │  │08-status │ │09-export │                                   │ │   │
│   │   │  └──────────┘ └──────────┘                                   │ │   │
│   │   └───────────────────────────────────────────────────────────────┘ │   │
│   │                                                                      │   │
│   │   ┌───────────────────────────────────────────────────────────────┐ │   │
│   │   │                    SHARED LIBRARIES                           │ │   │
│   │   │  common.sh │ colors.sh │ logging.sh │ docker.sh               │ │   │
│   │   └───────────────────────────────────────────────────────────────┘ │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                    ┌───────────────┼───────────────┐                        │
│                    │               │               │                        │
│                    ▼               ▼               ▼                        │
│              ┌──────────┐   ┌──────────┐   ┌──────────┐                    │
│              │  Volume  │   │  X11     │   │ Network  │                    │
│              │  Mounts  │   │  Socket  │   │ (VPN)    │                    │
│              └──────────┘   └──────────┘   └──────────┘                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Component Summary

| Component | Type | Purpose |
|-----------|------|---------|
| `cloud-connect.sh` | Entry Point | Host-side script to manage container |
| `modules/` | Feature Set | Independent functional modules |
| `configs/` | Defaults | Default configurations (anonymous mode) |
| `lib/` | Libraries | Shared shell functions |
| Docker Container | Runtime | Isolated Arch Linux environment |

---

## 2. Step-by-Step Flow

### 2.1 User Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        UNTRUSTED COMPUTER                                    │
│  (Only requires: Linux + Docker + Shell)                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 1: ISOLATED ANONYMOUS ENVIRONMENT                                      │
│  ═══════════════════════════════════════                                     │
│                                                                              │
│  User runs: ./cloud-connect.sh                                               │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ DOCKER CONTAINER (Arch Linux)                                          │ │
│  │                                                                        │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                 │ │
│  │  │  ProtonVPN   │  │ Encrypted    │  │    Brave     │                 │ │
│  │  │ (ready)      │  │   DNS (DoH)  │  │   Browser    │                 │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘                 │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                 │ │
│  │  │  Claude CLI  │  │  Gemini CLI  │  │  Modern CLI  │                 │ │
│  │  │  (v2.x)      │  │  (@google)   │  │ eza,bat,fd.. │                 │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘                 │ │
│  │                                                                        │ │
│  │  VNC Desktop (optional): CLOUD_START_VNC=1                            │ │
│  │  Resource Limits: 90% CPU, 90% RAM, Swap = RAM                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  → READY FOR ANONYMOUS WORK + AI DEVELOPMENT                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼ (optional)
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 2: ADD DEVELOPMENT TOOLS                                               │
│  ═════════════════════════════════                                           │
│                                                                              │
│  User runs: cloud tools install                                              │
│                                                                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐        │
│  │   Python     │ │   Node.js    │ │    Rust      │ │     Go       │        │
│  │ pip, poetry  │ │ npm, pnpm    │ │   cargo      │ │   go mod     │        │
│  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘        │
│                                                                              │
│  Optional: cloud desktop install  →  KDE Plasma Desktop                      │
│                                                                              │
│  → FULL DEVELOPMENT WORKSTATION (still anonymous)                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼ (optional)
┌─────────────────────────────────────────────────────────────────────────────┐
│  STEP 3: PERSONALIZE WITH VAULT                                              │
│  ═══════════════════════════════════                                         │
│                                                                              │
│  User runs: cloud vault load /path/to/vault                                  │
│                                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐                 │
│  │  VPN Keys      │  │  SSH Keys      │  │  Cloud Configs │                 │
│  │  → WireGuard   │  │  → SSH access  │  │  → rclone      │                 │
│  └────────────────┘  └────────────────┘  └────────────────┘                 │
│                                                                              │
│  → PERSONALIZED WORKSTATION CONNECTED TO CLOUD                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Flow Summary

| Step | Command | Result |
|------|---------|--------|
| 1 | `./cloud-connect.sh` | Anonymous container with DNS, AI CLIs |
| 1b | `CLOUD_START_VNC=1 ./cloud-connect.sh` | + VNC desktop on :5901 |
| 2a | `cloud tools install` | Development tools added |
| 3a | `cloud vault load <path>` | Personal vault loaded |
| 3b | `cloud vpn up` | WireGuard connected |
| 3c | `cloud mount up` | FUSE mounts active |
| 3d | `cloud config apply` | Personal configs applied |

---

## 3. Module Architecture

### 3.1 Module Overview

```
modules/
│
│  ═══ STEP 1: ANONYMOUS ENVIRONMENT ═══
├── 00-base/                    # Core: Anonymous isolated env
│   ├── Dockerfile              # Arch Linux + AI tools + VNC
│   ├── docker-compose.yml      # Container config + limits
│   ├── entrypoint.sh           # Container startup (DNS, VNC)
│   │
│   │   INCLUDED IN BASE IMAGE:
│   │   - ProtonVPN CLI (protonvpn-cli)
│   │   - Encrypted DNS (cloudflared)
│   │   - Brave browser (brave-bin)
│   │   - Claude CLI (claude)
│   │   - Gemini CLI (@google/gemini-cli)
│   │   - VNC Desktop (tigervnc, openbox, dolphin, konsole)
│   │   - Modern CLI (eza, bat, fd, rg, fzf, zoxide, starship)
│   │   - Shells (bash, fish, zsh)
│   │   - Home structure (apps, git, mnt, syncs, sys, user, vault)
│   │
│
│  ═══ STEP 2: DEVELOPMENT TOOLS ═══
├── 01-tools/                   # Optional: Dev stack
│   ├── install.sh              # Main installer
│   ├── python.sh               # Python + pip + poetry
│   ├── node.sh                 # Node.js + npm + pnpm
│   ├── rust.sh                 # Rust + cargo
│   ├── go.sh                   # Go
│   ├── git.sh                  # Git + lazygit + gh
│   └── cli.sh                  # ripgrep, fd, bat, eza, fzf
│
├── 02-desktop/                 # Optional: KDE Desktop
│   ├── Dockerfile.kde          # KDE Plasma layer
│   ├── desktop.sh              # Desktop setup
│   └── configs/                # KDE app configs
│
│  ═══ STEP 3: PERSONALIZATION ═══
├── 03-vault/                   # Optional: Personal vault
│   ├── vault.sh                # Load/decrypt vault
│   └── fetch.sh                # Fetch from remote
│
├── 04-vpn/                     # Requires vault: WireGuard
│   ├── wireguard.sh            # WireGuard setup
│   └── split-tunnel.sh         # Split tunnel routing
│
├── 05-ssh/                     # Requires vault: SSH
│   ├── ssh.sh                  # SSH key setup
│   └── connections.sh          # SSH to VMs
│
├── 06-mount/                   # Requires vault: FUSE
│   ├── mount.sh                # Mount manager
│   ├── rclone.sh               # rclone setup
│   └── sshfs.sh                # SSHFS mounts
│
├── 07-config/                  # Requires vault: Configs
│   ├── config.sh               # Apply configs
│   ├── shell.sh                # Shell configs
│   └── git-config.sh           # Git configs
│
│  ═══ UTILITIES ═══
├── 08-status/                  # Status & monitoring
│   ├── status.sh               # Overall status
│   ├── health.sh               # Health checks
│   └── topology.sh             # Network topology
│
└── 09-export/                  # Export data
    ├── export.sh               # Export manager
    └── report.sh               # Generate reports
```

### 3.2 Module Details

| Module | Purpose | Status | Depends On |
|--------|---------|--------|------------|
| **00-base** | Anonymous container + AI CLIs + VNC | Complete | Docker |
| **01-tools** | Dev tools (Python, Node, Rust, Go) | Planned | 00-base |
| **02-desktop** | Additional desktop features | Planned | 00-base |
| **03-vault** | Load vault | Planned | 00-base |
| **04-vpn** | WireGuard | Planned | 03-vault |
| **05-ssh** | SSH connections | Planned | 03-vault |
| **06-mount** | FUSE mounts | Planned | 03-vault |
| **07-config** | Personal configs | Planned | 03-vault |
| **08-status** | Status checks | Planned | 00-base |
| **09-export** | Export data | Planned | 00-base |

### 3.3 Module Dependency Graph

```
                          00-base (required)
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
          01-tools       02-desktop       03-vault
              │               │               │
              │               │    ┌──────────┼──────────┬──────────┐
              │               │    │          │          │          │
              ▼               ▼    ▼          ▼          ▼          ▼
          08-status      08-status  04-vpn   05-ssh   06-mount  07-config
                                       │          │          │          │
                                       └──────────┴──────────┴──────────┘
                                                      │
                                                      ▼
                                                  08-status
```

### 3.4 Module States

```
ANONYMOUS PATH (no vault):
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ 00-base  │ ──▶ │ 01-tools │ ──▶ │02-desktop│ ──▶ │08-status │
└──────────┘     └──────────┘     └──────────┘     └──────────┘

PERSONALIZED PATH (with vault):
┌──────────┐     ┌──────────┐     ┌─────────────────────────────────────┐
│ 00-base  │ ──▶ │ 03-vault │ ──▶ │ 04-vpn, 05-ssh, 06-mount, 07-config │
└──────────┘     └──────────┘     └─────────────────────────────────────┘
```

---

## 4. Network Architecture

### 4.1 Anonymous Mode (Default)

```
                    CONTAINER
                        │
                        ▼
              ┌─────────────────┐
              │   ProtonVPN     │
              │  (free tier)    │
              │   anonymous     │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  Encrypted DNS  │
              │   DoH / DoT     │
              │  (Cloudflare)   │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │    INTERNET     │
              │   (anonymous)   │
              └─────────────────┘
```

### 4.2 Personalized Mode (Split Tunnel)

```
                              CONTAINER
                                  │
                  ┌───────────────┼───────────────┐
                  │                               │
                  ▼                               ▼
         ┌─────────────────┐             ┌─────────────────┐
         │    WireGuard    │             │   ProtonVPN     │
         │  (personal VPN) │             │  (free tier)    │
         └────────┬────────┘             └────────┬────────┘
                  │                               │
                  ▼                               ▼
         ┌─────────────────┐             ┌─────────────────┐
         │  CLOUD INFRA    │             │    INTERNET     │
         │  - GCP VM       │             │   (anonymous)   │
         │  - OCI VMs      │             │                 │
         │  - 10.0.0.0/24  │             │                 │
         └─────────────────┘             └─────────────────┘

         Routes via WireGuard:           Routes via ProtonVPN:
         - 10.0.0.0/24                   - 0.0.0.0/0 (default)
         - Cloud VM public IPs
         - *.diegonmarcos.com
```

### 4.3 Split Tunnel Routing Table

| Destination | Route Via | Purpose |
|-------------|-----------|---------|
| `10.0.0.0/24` | WireGuard | Cloud LAN |
| `34.55.55.234/32` | WireGuard | GCP Hub |
| `84.235.234.87/32` | WireGuard | OCI Flex |
| `130.110.251.193/32` | WireGuard | OCI Mail |
| `129.151.228.66/32` | WireGuard | OCI Analytics |
| `192.168.0.0/16` | Direct | Local LAN |
| `0.0.0.0/0` | ProtonVPN | Public Internet |

---

## 5. Folder Structure

### 5.1 Complete Structure

```
cloud_connect/
│
├── cloud-connect.sh              # ENTRY POINT
│
├── modules/                      # FEATURE MODULES
│   ├── 00-base/
│   ├── 01-tools/
│   ├── 02-desktop/
│   ├── 03-vault/
│   ├── 04-vpn/
│   ├── 05-ssh/
│   ├── 06-mount/
│   ├── 07-config/
│   ├── 08-status/
│   └── 09-export/
│
├── configs/                      # DEFAULT CONFIGS
│   ├── dns/
│   │   ├── cloudflare.conf
│   │   └── quad9.conf
│   ├── protonvpn/
│   │   └── default.conf
│   ├── shell/
│   │   ├── aliases.sh
│   │   ├── fish.fish
│   │   └── starship.toml
│   └── brave/
│       └── extensions.txt
│
├── lib/                          # SHARED LIBRARIES
│   ├── common.sh
│   ├── colors.sh
│   ├── logging.sh
│   └── docker.sh
│
├── 0.spec/                       # DOCUMENTATION
│   ├── SPEC.md
│   ├── ARCHITECTURE.md
│   ├── DESIGN.md
│   └── IMPLEMENTATION.md
│
└── legacy/                       # OLD CODE (reference)
    └── src/
```

### 5.2 File Purposes

| Path | Purpose |
|------|---------|
| `cloud-connect.sh` | Host-side entry point |
| `modules/*/` | Self-contained feature modules |
| `configs/` | Default anonymous-mode configs |
| `lib/` | Shared shell functions |
| `0.spec/` | Project documentation |
| `legacy/` | Old Rust implementation (reference) |

---

## 6. Data Flow

### 6.1 Container Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CONTAINER LIFECYCLE                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   CREATE                     RUN                        DESTROY              │
│   ───────                   ─────                      ─────────             │
│                                                                              │
│   ./cloud-connect.sh        cloud <module> <cmd>       ./cloud-connect.sh   │
│         │                         │                          stop           │
│         ▼                         ▼                           │              │
│   ┌──────────┐             ┌──────────┐                       ▼              │
│   │  Build   │             │  Exec    │                ┌──────────┐         │
│   │  Image   │             │  Module  │                │  Remove  │         │
│   └────┬─────┘             └────┬─────┘                │Container │         │
│        │                        │                      └──────────┘         │
│        ▼                        ▼                                            │
│   ┌──────────┐             ┌──────────┐                                     │
│   │  Start   │             │  Module  │                                     │
│   │Container │             │  Output  │                                     │
│   └────┬─────┘             └──────────┘                                     │
│        │                                                                     │
│        ▼                                                                     │
│   ┌──────────┐                                                              │
│   │  Enter   │                                                              │
│   │  Shell   │                                                              │
│   └──────────┘                                                              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Vault Loading Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           VAULT LOADING FLOW                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   cloud vault load /path/to/vault                                            │
│         │                                                                    │
│         ▼                                                                    │
│   ┌──────────────┐                                                          │
│   │ Verify Path  │                                                          │
│   └──────┬───────┘                                                          │
│          │                                                                   │
│          ▼                                                                   │
│   ┌──────────────┐     ┌──────────────┐                                     │
│   │  Encrypted?  │────▶│   Decrypt    │                                     │
│   └──────┬───────┘     └──────┬───────┘                                     │
│          │                    │                                              │
│          ▼                    ▼                                              │
│   ┌──────────────────────────────────────┐                                  │
│   │         Mount Read-Only              │                                  │
│   │         at /vault                    │                                  │
│   └──────────────────┬───────────────────┘                                  │
│                      │                                                       │
│          ┌───────────┼───────────┬───────────┐                              │
│          ▼           ▼           ▼           ▼                              │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                      │
│   │ SSH Keys │ │ VPN Keys │ │  rclone  │ │ Configs  │                      │
│   │ ~/.ssh/  │ │ /etc/wg/ │ │ ~/.config│ │ various  │                      │
│   └──────────┘ └──────────┘ └──────────┘ └──────────┘                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Security Architecture

### 7.1 Security Layers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SECURITY LAYERS                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  LAYER 4: SPLIT TUNNEL (personalized mode)                                   │
│  ├── Cloud traffic → Personal WireGuard                                     │
│  ├── Public traffic → ProtonVPN                                             │
│  └── Local traffic → Direct                                                 │
│                                                                              │
│  LAYER 3: VAULT SECURITY (when loaded)                                       │
│  ├── Vault encrypted at rest                                                │
│  ├── SSH keys 4096-bit RSA/Ed25519                                          │
│  ├── WireGuard ChaCha20-Poly1305                                            │
│  └── Vault mounted read-only                                                │
│                                                                              │
│  LAYER 2: NETWORK ENCRYPTION (always)                                        │
│  ├── ProtonVPN (anonymous, free tier)                                       │
│  ├── Encrypted DNS (DoH/DoT)                                                │
│  └── No plaintext DNS queries                                               │
│                                                                              │
│  LAYER 1: CONTAINER ISOLATION (always)                                       │
│  ├── Docker container boundaries                                            │
│  ├── Limited volume mounts                                                  │
│  ├── No host root access                                                    │
│  └── Ephemeral by default                                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Threat Mitigations

| Threat | Layer | Mitigation |
|--------|-------|------------|
| Host keylogger | 1 | Container isolation |
| Network sniffing | 2 | VPN encryption |
| DNS leaks | 2 | DoH/DoT enforced |
| Credential theft | 3 | Vault read-only, encrypted |
| Traffic analysis | 4 | Split tunnel |

---

## 8. CLI Architecture

### 8.1 Command Tree

```
cloud-connect.sh
│
├── start / up              # Create and enter container
├── enter / shell           # Enter existing container
├── stop / down             # Stop container
│
├── tools                   # Module: 01-tools
│   ├── install [tool...]
│   ├── list
│   └── check
│
├── desktop                 # Module: 02-desktop
│   ├── install
│   ├── start
│   └── stop
│
├── vault                   # Module: 03-vault
│   ├── load <path>
│   ├── fetch <url>
│   ├── status
│   └── unload
│
├── vpn                     # Module: 04-vpn
│   ├── up
│   ├── down
│   ├── status
│   ├── split
│   └── full
│
├── ssh                     # Module: 05-ssh
│   ├── to <vm>
│   ├── list
│   └── setup
│
├── mount                   # Module: 06-mount
│   ├── up [remote]
│   ├── down [remote]
│   ├── list
│   └── status
│
├── config                  # Module: 07-config
│   ├── apply
│   ├── shell
│   ├── git
│   └── apps
│
├── status                  # Module: 08-status
│   ├── health
│   ├── topology
│   └── vms
│
└── export                  # Module: 09-export
    ├── topology
    ├── report
    └── all
```

### 8.2 Command Routing

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           COMMAND ROUTING                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ./cloud-connect.sh <cmd> [args...]                                         │
│         │                                                                    │
│         ▼                                                                    │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │                        ROUTER                                         │  │
│   │                                                                       │  │
│   │   case "$cmd" in                                                      │  │
│   │     start|up)    → create_container && enter_container               │  │
│   │     stop|down)   → docker compose down                               │  │
│   │     tools)       → docker exec ... modules/01-tools/install.sh       │  │
│   │     desktop)     → docker exec ... modules/02-desktop/desktop.sh     │  │
│   │     vault)       → docker exec ... modules/03-vault/vault.sh         │  │
│   │     vpn)         → docker exec ... modules/04-vpn/wireguard.sh       │  │
│   │     ssh)         → docker exec ... modules/05-ssh/ssh.sh             │  │
│   │     mount)       → docker exec ... modules/06-mount/mount.sh         │  │
│   │     config)      → docker exec ... modules/07-config/config.sh       │  │
│   │     status)      → docker exec ... modules/08-status/status.sh       │  │
│   │     export)      → docker exec ... modules/09-export/export.sh       │  │
│   │   esac                                                                │  │
│   │                                                                       │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. References

- [SPEC.md](SPEC.md) - Requirements and features
- [DESIGN.md](DESIGN.md) - Design decisions and trade-offs
- [IMPLEMENTATION.md](IMPLEMENTATION.md) - Build phases and tasks

---

*End of Architecture*
