# Cloud Connect - Specification

> **Document Type**: Requirements & Features
> **Version**: 2.0
> **Last Updated**: 2026-01-01

---

## 1. Overview

### 1.1 What is Cloud Connect?

**Cloud Connect Scripts/Tools** is a modular toolkit for bootstrapping secure, isolated work environments on untrusted computers.

### 1.2 Problem Statement

**Scenario**: User is on an untrusted/temporary computer (public machine, borrowed laptop, fresh install) and needs to:

1. Work in an isolated environment that doesn't touch the host system
2. Have anonymous network connectivity (no tracking, no leaks)
3. Optionally install development tools
4. Optionally connect to personal cloud infrastructure
5. Optionally sync files and apply personal configurations

**Constraint**: The host system only has Linux + Docker + Shell. No additional dependencies.

### 1.3 Solution

A portable shell script that creates a Docker container with:
- Anonymous networking (VPN + encrypted DNS)
- Optional development tools
- Optional personal vault integration

---

## 2. Requirements

### 2.1 Functional Requirements

#### FR-01: Anonymous Isolated Environment (Core)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-01.1 | Create Docker container from single shell script | Must |
| FR-01.2 | Container runs Arch Linux | Must |
| FR-01.3 | ProtonVPN free tier pre-configured | Must |
| FR-01.4 | Encrypted DNS (DoH/DoT) enabled | Must |
| FR-01.5 | Brave browser installed | Must |
| FR-01.6 | User has sudo access inside container | Must |
| FR-01.7 | No personal data required to function | Must |

#### FR-02: Resource Safety (Core)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-02.1 | CPU limited to 90% of host | Must |
| FR-02.2 | RAM limited to 90% of host | Must |
| FR-02.3 | Swap equal to RAM limit | Must |
| FR-02.4 | Container killed first on OOM (not host) | Must |
| FR-02.5 | Limits auto-calculated based on host | Should |

#### FR-03: Development Tools (Optional)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-03.1 | Python stack (pip, poetry) | Should |
| FR-03.2 | Node.js stack (npm, pnpm) | Should |
| FR-03.3 | Rust stack (cargo, rustup) | Should |
| FR-03.4 | Go stack | Should |
| FR-03.5 | Git tools (lazygit, gh, delta) | Should |
| FR-03.6 | CLI utilities (ripgrep, fd, bat, eza, fzf) | Should |
| FR-03.7 | Tools installed on-demand, not by default | Must |

#### FR-04: Desktop Environment (Optional)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-04.1 | VNC server (TigerVNC) | Complete |
| FR-04.2 | Lightweight WM (Openbox) | Complete |
| FR-04.3 | Qt apps (Dolphin, Konsole) | Complete |
| FR-04.4 | Desktop disabled by default (CLOUD_START_VNC=1) | Complete |
| FR-04.5 | X11 forwarding to host display | Complete |

#### FR-04b: AI CLI Tools (Base)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-04b.1 | Claude CLI pre-installed | Complete |
| FR-04b.2 | Gemini CLI pre-installed | Complete |
| FR-04b.3 | Global CLI access (/usr/local/bin) | Complete |

#### FR-05: Vault Integration (Optional)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-05.1 | Load encrypted vault from path | Should |
| FR-05.2 | Fetch vault from remote URL | Could |
| FR-05.3 | Decrypt vault with user password | Should |
| FR-05.4 | Mount vault read-only | Should |

#### FR-06: Personal VPN (Optional, requires vault)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-06.1 | WireGuard connection to personal infrastructure | Should |
| FR-06.2 | Split tunnel (cloud via WG, public via ProtonVPN) | Should |
| FR-06.3 | Full tunnel mode option | Should |
| FR-06.4 | VPN status monitoring | Should |

#### FR-07: SSH Connections (Optional, requires vault)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-07.1 | Load SSH keys from vault | Should |
| FR-07.2 | SSH to configured VMs | Should |
| FR-07.3 | List available VM connections | Should |

#### FR-08: FUSE Mounts (Optional, requires vault)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-08.1 | rclone mount to cloud storage | Should |
| FR-08.2 | SSHFS mount to VMs | Should |
| FR-08.3 | Mount/unmount individual remotes | Should |
| FR-08.4 | Mount status display | Should |

#### FR-09: Personal Configuration (Optional, requires vault)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-09.1 | Apply shell configs (fish, zsh, starship) | Should |
| FR-09.2 | Apply git config (user, aliases) | Should |
| FR-09.3 | Apply app configs (editor, browser) | Could |

#### FR-10: Status & Monitoring

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-10.1 | Show overall system status | Should |
| FR-10.2 | Health checks (VPN, mounts, network) | Should |
| FR-10.3 | Network topology view | Could |
| FR-10.4 | VM status (if vault loaded) | Could |

#### FR-11: Export

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-11.1 | Export topology diagram | Could |
| FR-11.2 | Export health report | Could |
| FR-11.3 | Export configuration | Could |

### 2.2 Non-Functional Requirements

#### NFR-01: Portability

| ID | Requirement |
|----|-------------|
| NFR-01.1 | Entry point is a single shell script |
| NFR-01.2 | Works on any Linux with Docker |
| NFR-01.3 | No compilation required |
| NFR-01.4 | No external dependencies beyond Docker |

#### NFR-02: Modularity

| ID | Requirement |
|----|-------------|
| NFR-02.1 | Each feature is a separate module |
| NFR-02.2 | Modules can run independently |
| NFR-02.3 | Modules can be skipped |
| NFR-02.4 | No hidden inter-module dependencies |

#### NFR-03: Security

| ID | Requirement |
|----|-------------|
| NFR-03.1 | Container isolated from host filesystem |
| NFR-03.2 | All network traffic encrypted (VPN) |
| NFR-03.3 | DNS queries encrypted (DoH/DoT) |
| NFR-03.4 | Vault mounted read-only |
| NFR-03.5 | No credentials stored in container image |

#### NFR-04: Performance

| ID | Requirement |
|----|-------------|
| NFR-04.1 | Container starts in < 30 seconds |
| NFR-04.2 | Base image < 2GB |
| NFR-04.3 | Full image with tools < 10GB |

#### NFR-05: Usability

| ID | Requirement |
|----|-------------|
| NFR-05.1 | Single command to start |
| NFR-05.2 | Clear CLI help messages |
| NFR-05.3 | Progress feedback during operations |

---

## 3. Features

### 3.1 Feature Summary

| Feature | Description | Default | Status |
|---------|-------------|---------|--------|
| **Anonymous Environment** | ProtonVPN + Encrypted DNS + Brave | Yes | Complete |
| **AI CLI Tools** | Claude CLI + Gemini CLI | Yes | Complete |
| **Modern CLI** | eza, bat, fd, rg, fzf, zoxide, starship | Yes | Complete |
| **VNC Desktop** | TigerVNC + Openbox + Qt apps | No | Complete |
| **Home Structure** | Mirrors host layout | Yes | Complete |
| **Resource Limits** | 90% CPU/RAM caps | Yes | Complete |
| **Development Tools** | Python, Node, Rust, Go, Git | No | Planned |
| **Vault Integration** | Load personal encrypted vault | No | Planned |
| **Personal VPN** | WireGuard to cloud infrastructure | No | Planned |
| **SSH Connections** | SSH to configured VMs | No | Planned |
| **FUSE Mounts** | rclone/sshfs mounts | No | Planned |
| **Personal Config** | Shell, git, app configs | No | Planned |

### 3.2 Feature Dependencies

```
Anonymous Environment (always - base)
├── AI CLI Tools (always - base)
├── Modern CLI (always - base)
├── VNC Desktop (optional - CLOUD_START_VNC=1)
│
├── Development Tools (optional)
│
└── Vault Integration (optional)
    ├── Personal VPN (WireGuard)
    ├── SSH Connections
    ├── FUSE Mounts
    └── Personal Config
```

---

## 4. User Stories

### 4.1 Anonymous Work with AI

> As a user on a public computer, I want to quickly create an anonymous isolated environment with AI tools so I can work securely.

**Acceptance Criteria**:
- Run single script: `./cloud-connect.sh`
- Container starts with encrypted DNS
- Claude CLI and Gemini CLI available
- Brave browser available
- No personal data required

### 4.2 Remote Desktop Access

> As a user who wants a graphical environment, I want to connect via VNC so I can use desktop apps.

**Acceptance Criteria**:
- Run: `CLOUD_START_VNC=1 ./cloud-connect.sh`
- VNC server available on port 5901
- Brave, Dolphin, Konsole accessible
- Openbox window manager functional

### 4.3 Development Work

> As a developer on a borrowed laptop, I want to install my development tools so I can write code without configuring the host.

**Acceptance Criteria**:
- Run: `cloud tools install python node rust`
- Tools installed inside container
- Host system unchanged

### 4.4 Personal Cloud Access

> As a user with cloud infrastructure, I want to connect to my VMs and mount my storage so I can access my files.

**Acceptance Criteria**:
- Load vault: `cloud vault load /path/to/vault`
- Connect VPN: `cloud vpn up`
- Mount storage: `cloud mount up`
- Access files at `~/mnt/`

---

## 5. Constraints

### 5.1 Technical Constraints

| Constraint | Reason |
|------------|--------|
| Linux host only | Docker + shell requirement |
| Docker required | Container isolation |
| 90% resource limit | Prevent host crash |
| Arch Linux in container | Package availability |

### 5.2 Design Constraints

| Constraint | Reason |
|------------|--------|
| Shell entry point | Maximum portability |
| Anonymous by default | Privacy-first design |
| Vault optional | Not all users need personalization |
| Modular architecture | Flexibility, maintainability |

---

## 6. Glossary

| Term | Definition |
|------|------------|
| **Vault** | Encrypted directory containing personal keys, configs, credentials |
| **Module** | Self-contained script/tool for a specific function |
| **Anonymous Mode** | Default state with ProtonVPN, no personal data |
| **Personalized Mode** | State after loading vault with personal configs |
| **Split Tunnel** | Cloud traffic via WireGuard, public via ProtonVPN |
| **FUSE Mount** | Filesystem in Userspace - mount remote storage locally |

---

## 7. References

- [ARCHITECTURE.md](ARCHITECTURE.md) - System structure and modules
- [DESIGN.md](DESIGN.md) - Design decisions and trade-offs
- [IMPLEMENTATION.md](IMPLEMENTATION.md) - Build phases and tasks

---

*End of Specification*
