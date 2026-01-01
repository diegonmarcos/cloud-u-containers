# Cloud Connect - Implementation Plan

> **Document Type**: Build Phases & Tasks
> **Version**: 2.0
> **Last Updated**: 2026-01-01

---

## 1. Overview

This document defines the implementation phases, tasks, and order of work for building Cloud Connect.

### 1.1 Implementation Approach

- **Incremental**: Each phase delivers working functionality
- **Testable**: Each module can be tested independently
- **Documented**: Code and usage documented as we go

### 1.2 Phase Summary

| Phase | Name | Deliverable |
|-------|------|-------------|
| 1 | Foundation | Entry point + base container |
| 2 | Development Tools | Tool installers |
| 3 | Desktop | KDE Plasma module |
| 4 | Personalization | Vault + VPN + SSH + mounts |
| 5 | Utilities | Status + export |
| 6 | Polish | Docs, testing, optimization |

---

## 2. Phase 1: Foundation

**Goal**: Create working anonymous environment.

**Deliverable**: User can run `./cloud-connect.sh` and get anonymous container.

### 2.1 Tasks

#### Task 1.1: Project Structure - COMPLETE

- [x] Create directory structure
- [x] Create modules folders
- [x] Create lib folder
- [x] Create configs folder

#### Task 1.2: Shared Libraries - COMPLETE

- [x] Create `lib/common.sh`
- [x] Create `lib/colors.sh`
- [x] Create `lib/logging.sh`
- [x] Create `lib/docker.sh`

#### Task 1.3: Entry Point Script - COMPLETE

- [x] Parse command line arguments
- [x] Route to appropriate module
- [x] Handle container lifecycle (up/down/enter)
- [x] Calculate resource limits (90% CPU/RAM)
- [x] Make executable

#### Task 1.4: Base Dockerfile - COMPLETE

- [x] Start from `archlinux:latest`
- [x] Install base system utilities
- [x] Create non-root user (clouduser)
- [x] Configure sudo (passwordless)
- [x] Set up entrypoint
- [x] Install VNC + Openbox (TigerVNC)
- [x] Install Qt apps (Dolphin, Konsole)
- [x] Install Claude CLI
- [x] Install Gemini CLI
- [x] Install modern CLI tools
- [x] Create home folder structure

#### Task 1.5: Docker Compose - COMPLETE

- [x] Configure resource limits
- [x] Set up volume mounts
- [x] Configure networking (host mode)
- [x] Set container name

#### Task 1.6: ProtonVPN Setup - COMPLETE

- [x] Install ProtonVPN CLI
- [x] Configure in entrypoint
- [x] Status check command

#### Task 1.7: Encrypted DNS - COMPLETE

- [x] Install cloudflared
- [x] Configure Cloudflare DoH
- [x] Auto-start in entrypoint

#### Task 1.8: Brave Browser - COMPLETE

- [x] Install Brave from AUR
- [x] Works in VNC desktop

### 2.2 Testing Phase 1 - COMPLETE

```bash
# All tests pass:
# - Container starts successfully
# - Encrypted DNS active
# - Claude CLI v2.0.76 working
# - Gemini CLI v0.22.5 working
# - VNC desktop works (when enabled)
# - Brave browser works
# - Modern CLI tools work
```

### 2.3 Phase 1 Checklist - COMPLETE

- [x] `./cloud-connect.sh` creates container
- [x] Container starts in < 30 seconds
- [x] ProtonVPN CLI available
- [x] DNS encrypted (cloudflared)
- [x] Brave browser works
- [x] Resource limits enforced (90%)
- [x] User has sudo
- [x] Claude CLI works
- [x] Gemini CLI works
- [x] VNC desktop works (optional)

---

## 3. Phase 2: Development Tools

**Goal**: Add optional development tools.

**Deliverable**: User can run `cloud tools install python` to add tools.

### 3.1 Tasks

#### Task 2.1: Tool Installer Framework

Create `modules/01-tools/install.sh`:

- [ ] Parse tool arguments
- [ ] Call individual tool installers
- [ ] Show progress
- [ ] Verify installation

#### Task 2.2: Python Installer

Create `modules/01-tools/python.sh`:

- [ ] Install Python 3
- [ ] Install pip
- [ ] Install poetry
- [ ] Install common packages (numpy, pandas)

#### Task 2.3: Node.js Installer

Create `modules/01-tools/node.sh`:

- [ ] Install Node.js LTS
- [ ] Install npm
- [ ] Install pnpm
- [ ] Install yarn

#### Task 2.4: Rust Installer

Create `modules/01-tools/rust.sh`:

- [ ] Install rustup
- [ ] Install stable toolchain
- [ ] Install rust-analyzer
- [ ] Install cargo tools (cargo-watch, cargo-edit)

#### Task 2.5: Go Installer

Create `modules/01-tools/go.sh`:

- [ ] Install Go
- [ ] Configure GOPATH
- [ ] Install common tools

#### Task 2.6: Git Tools

Create `modules/01-tools/git.sh`:

- [ ] Install git
- [ ] Install lazygit
- [ ] Install gh (GitHub CLI)
- [ ] Install delta
- [ ] Install tig

#### Task 2.7: CLI Utilities

Create `modules/01-tools/cli.sh`:

- [ ] Install ripgrep
- [ ] Install fd
- [ ] Install bat
- [ ] Install eza
- [ ] Install fzf
- [ ] Install zoxide
- [ ] Install btop

### 3.2 Phase 2 Checklist

- [ ] `cloud tools install python` works
- [ ] `cloud tools install node` works
- [ ] `cloud tools install rust` works
- [ ] `cloud tools install go` works
- [ ] `cloud tools install git` works
- [ ] `cloud tools install cli` works
- [ ] `cloud tools list` shows available
- [ ] `cloud tools check` shows installed

---

## 4. Phase 3: Desktop

**Goal**: Add optional KDE Plasma desktop.

**Deliverable**: User can run `cloud desktop install` to add KDE.

### 4.1 Tasks

#### Task 3.1: KDE Dockerfile Layer

Create `modules/02-desktop/Dockerfile.kde`:

- [ ] Extend base image
- [ ] Install Xorg
- [ ] Install KDE Plasma
- [ ] Install KDE apps (Dolphin, Konsole, Kate)
- [ ] Install Yakuake

#### Task 3.2: Desktop Script

Create `modules/02-desktop/desktop.sh`:

- [ ] Start X11/Wayland
- [ ] Launch Plasma
- [ ] Handle display forwarding

#### Task 3.3: Desktop Configs

Create `modules/02-desktop/configs/`:

- [ ] Konsole profile
- [ ] Kate settings
- [ ] Dolphin settings
- [ ] Yakuake settings

### 4.2 Phase 3 Checklist

- [ ] `cloud desktop install` works
- [ ] KDE Plasma starts
- [ ] X11 forwarding works
- [ ] Konsole, Kate, Dolphin work
- [ ] Yakuake works (F12)

---

## 5. Phase 4: Personalization

**Goal**: Add vault loading and personal cloud access.

**Deliverable**: User can load vault and connect to personal infrastructure.

### 5.1 Tasks

#### Task 4.1: Vault Module

Create `modules/03-vault/vault.sh`:

- [ ] Load vault from path
- [ ] Verify vault structure
- [ ] Mount read-only
- [ ] Export vault paths

#### Task 4.2: VPN Module

Create `modules/04-vpn/wireguard.sh`:

- [ ] Load WireGuard config from vault
- [ ] Connect to WireGuard
- [ ] Implement split tunnel
- [ ] Status command

#### Task 4.3: SSH Module

Create `modules/05-ssh/ssh.sh`:

- [ ] Load SSH keys from vault
- [ ] Configure ssh-agent
- [ ] SSH to VMs command
- [ ] List VMs command

#### Task 4.4: Mount Module

Create `modules/06-mount/mount.sh`:

- [ ] Load rclone config from vault
- [ ] Mount remotes
- [ ] Unmount remotes
- [ ] Status command

#### Task 4.5: Config Module

Create `modules/07-config/config.sh`:

- [ ] Apply shell configs from vault
- [ ] Apply git config from vault
- [ ] Apply app configs from vault

### 5.2 Phase 4 Checklist

- [ ] `cloud vault load /path` works
- [ ] `cloud vpn up` connects WireGuard
- [ ] `cloud vpn split` enables split tunnel
- [ ] `cloud ssh to gcp` works
- [ ] `cloud mount up` mounts remotes
- [ ] `cloud config apply` applies configs

---

## 6. Phase 5: Utilities

**Goal**: Add status and export modules.

**Deliverable**: User can check status and export data.

### 6.1 Tasks

#### Task 5.1: Status Module

Create `modules/08-status/status.sh`:

- [ ] Overall status display
- [ ] VPN status
- [ ] Mount status
- [ ] Health checks

#### Task 5.2: Topology View

Create `modules/08-status/topology.sh`:

- [ ] ASCII network diagram
- [ ] VM status table
- [ ] Ping checks

#### Task 5.3: Export Module

Create `modules/09-export/export.sh`:

- [ ] Export topology (ASCII, JSON)
- [ ] Export health report
- [ ] Export configuration

### 6.2 Phase 5 Checklist

- [ ] `cloud status` shows overview
- [ ] `cloud status health` runs checks
- [ ] `cloud status topology` shows diagram
- [ ] `cloud export topology` exports data
- [ ] `cloud export report` generates report

---

## 7. Phase 6: Polish

**Goal**: Finalize documentation, testing, optimization.

**Deliverable**: Production-ready release.

### 7.1 Tasks

#### Task 6.1: Documentation

- [ ] Update README.md
- [ ] Add usage examples
- [ ] Add troubleshooting guide
- [ ] Add contribution guide

#### Task 6.2: Testing

- [ ] Test on clean Ubuntu
- [ ] Test on clean Fedora
- [ ] Test on Arch host
- [ ] Test with minimal Docker

#### Task 6.3: Optimization

- [ ] Optimize Docker image size
- [ ] Reduce startup time
- [ ] Cache package downloads
- [ ] Parallel installations

#### Task 6.4: Error Handling

- [ ] Add error handling to all scripts
- [ ] Improve error messages
- [ ] Add recovery suggestions

### 7.2 Phase 6 Checklist

- [ ] All documentation complete
- [ ] Tested on 3+ distros
- [ ] Image size < 2GB (base)
- [ ] Startup < 30 seconds
- [ ] All errors have helpful messages

---

## 8. Task Dependencies

```
Phase 1: Foundation (REQUIRED)
    │
    ├──▶ Phase 2: Tools (optional)
    │         │
    │         └──▶ Phase 3: Desktop (optional)
    │
    └──▶ Phase 4: Personalization (optional)
              │
              └──▶ Phase 5: Utilities (optional)

Phase 6: Polish (after any phase)
```

---

## 9. Milestones

| Milestone | Criteria | Phase |
|-----------|----------|-------|
| **M1: Anonymous Ready** | Container with VPN works | 1 |
| **M2: Dev Ready** | All tools installable | 2 |
| **M3: Desktop Ready** | KDE Plasma works | 3 |
| **M4: Cloud Ready** | Vault + VPN + mounts work | 4 |
| **M5: Complete** | All features, documented | 5-6 |

---

## 10. Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| ProtonVPN API changes | VPN breaks | Pin version, monitor updates |
| Arch package breaks | Build fails | Use specific package versions |
| Docker compatibility | Doesn't run | Test on multiple Docker versions |
| X11 forwarding issues | Desktop fails | Support Wayland as backup |
| Resource limit bypass | Host crashes | Kernel-level enforcement |

---

## 11. Definition of Done

Each task is "done" when:

1. Code is written and works
2. Can be run independently
3. Error handling in place
4. Basic documentation exists
5. Tested manually
6. Committed to git

Each phase is "done" when:

1. All tasks complete
2. Integration tested
3. Checklist passed
4. Documentation updated

---

## 12. Getting Started

### 12.1 Start Phase 1

```bash
cd /home/diego/git/cloud/a_solutions/front-apps/cloud_connect

# Create structure
mkdir -p modules/{00-base,01-tools,02-desktop,03-vault,04-vpn,05-ssh,06-mount,07-config,08-status,09-export}
mkdir -p configs/{dns,protonvpn,shell,brave}
mkdir -p lib

# Create entry point
touch cloud-connect.sh
chmod +x cloud-connect.sh

# Create first module
touch modules/00-base/{Dockerfile,docker-compose.yml,entrypoint.sh}
```

### 12.2 First Working Version

Priority order for Phase 1:
1. `cloud-connect.sh` (entry point)
2. `modules/00-base/Dockerfile`
3. `modules/00-base/docker-compose.yml`
4. `modules/00-base/entrypoint.sh`
5. Test container starts
6. Add ProtonVPN
7. Add DNS
8. Add Brave

---

## 13. References

- [SPEC.md](SPEC.md) - Requirements and features
- [ARCHITECTURE.md](ARCHITECTURE.md) - System structure
- [DESIGN.md](DESIGN.md) - Design decisions

---

*End of Implementation Plan*
