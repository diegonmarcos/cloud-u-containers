# Cloud Connect

> Portable, encrypted KDE desktop environment in Docker with full development stack

[![Arch Linux](https://img.shields.io/badge/Arch-Linux-1793D1?logo=arch-linux&logoColor=white)](https://archlinux.org/)
[![KDE Plasma](https://img.shields.io/badge/KDE-Plasma-1D99F3?logo=kde&logoColor=white)](https://kde.org/)
[![Rust](https://img.shields.io/badge/Built%20with-Rust-orange?logo=rust)](https://www.rust-lang.org/)
[![Docker](https://img.shields.io/badge/Docker-Container-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)

---

## Table of Contents

- [A) How to Use](#a-how-to-use)
- [B) What is This](#b-what-is-this)
- [C) UI Designs](#c-ui-designs)
- [D) Architecture](#d-architecture)
- [E) Stack and Resource Usage](#e-stack-and-resource-usage)
- [F) Technical Specification](#f-technical-specification)
- [G) Roadmap](#g-roadmap)
- [H) References & Links](#h-references--links)

---

## A) How to Use

### A.1) Installation

#### Build from Source

```bash
cargo build --release
./target/release/cloud
```

#### Create Desktop Sandbox

```bash
# Create a new desktop sandbox
cloud setup sandbox create mydesktop

# Enter the sandbox
cloud setup sandbox enter mydesktop

# List all sandboxes
cloud setup sandbox list

# Destroy a sandbox
cloud setup sandbox destroy mydesktop --force
```

#### Create Bootable USB

```bash
# List available USB devices
cloud setup usb list

# Download latest Arch ISO
cloud setup usb download

# Create encrypted bootable USB (minimum 16GB)
cloud setup usb create /dev/sdX

# With custom ISO
cloud setup usb create /dev/sdX --iso ~/Downloads/archlinux.iso
```

#### First Login

| Credential | Value |
|------------|-------|
| **Username** | `diegonmarcos` |
| **Password** | `changeme` |

> **You MUST change the password on first login** - the system enforces this.

#### Auto-Cloned Repositories

On first login, the following repositories are automatically cloned to `~/Projects`:

| Repository | Path | Description |
|------------|------|-------------|
| **cloud** | `~/Projects/cloud` | Backend, infrastructure, cloud configs |
| **front-Github_io** | `~/Projects/front-Github_io` | Frontend, GitHub Pages projects |
| **ops-Tooling** | `~/Projects/ops-Tooling` | DevOps tools and utilities |
| **MyVault** | `~/Projects/MyVault` | Personal vault (copy manually) |

```bash
# Quick navigation
cloud       # cd ~/Projects/cloud
front       # cd ~/Projects/front-Github_io
ops         # cd ~/Projects/ops-Tooling
vault       # cd ~/Projects/MyVault
proj        # cd ~/Projects

# Sync all repos
sync-all    # Pull latest for all projects

# Re-run clone script
repos       # Run setup-repos again
```

#### CLI Commands Reference

```bash
cloud setup sandbox create <name>    # Create KDE desktop container
cloud setup sandbox enter <name>     # Enter container shell
cloud setup sandbox list             # List all containers
cloud setup sandbox destroy <name>   # Remove container

cloud setup usb list                 # List USB devices
cloud setup usb download             # Download Arch ISO
cloud setup usb verify <iso>         # Verify ISO checksum
cloud setup usb create <device>      # Create bootable USB

cloud setup apps install             # Install configured apps
cloud setup apps list                # List available apps
cloud setup apps check               # Check installed status

cloud setup check                    # Run all setup checks
```

---

### A.2) Tools & Aliases

#### Shell Configuration

| Shell | Default | Features |
|-------|---------|----------|
| **Fish** | Yes | Autosuggestions, syntax highlighting, smart completions |
| **Zsh** | No | Plugin support, POSIX-compatible, shared aliases |
| **Starship** | Prompt | Cross-shell prompt with git status, language versions |

```bash
fish    # Switch to Fish (default)
zsh     # Switch to Zsh
```

#### Pre-installed Stack

| Category | Tools | Description |
|----------|-------|-------------|
| **Desktop** | KDE Plasma | Full desktop environment with Wayland/X11 |
| | Dolphin | KDE file manager with previews and plugins |
| | Konsole | KDE terminal emulator |
| | Kate | Advanced text editor with LSP support |
| | Yakuake | Drop-down terminal (F12) |
| **Browsers** | Brave | Privacy-focused Chromium browser |
| **Notes** | Obsidian | Markdown-based knowledge management |
| **IDE** | VS Code | Full IDE with extensions support |
| | Neovim | Terminal-based editor |
| **Security** | Bitwarden | Password manager (desktop + CLI) |
| | ProtonVPN | Privacy-focused VPN client |
| | WireGuard | Fast, modern VPN protocol |
| **AI Tools** | Claude CLI | Anthropic's Claude Code assistant |
| | Gemini | Google's Gemini AI |
| **Cloud Sync** | rclone | Sync files to 40+ cloud providers |
| **Python** | Python 3 | Interpreter with pip, poetry |
| | NumPy/Pandas | Data science libraries |
| | Jupyter | Interactive notebooks |
| | Black/Pylint | Formatters and linters |
| **Node.js** | Node LTS | JavaScript runtime |
| | npm/pnpm/yarn | Package managers |
| | TypeScript | Type-safe JavaScript |
| | ESLint/Biome | Linters and formatters |
| **Rust** | rustup | Toolchain manager |
| | cargo | Package manager and build tool |
| | rust-analyzer | LSP for IDE integration |
| | clippy/rustfmt | Linter and formatter |
| **Go** | go | Go compiler and tools |
| **Containers** | Docker | Container runtime |
| | Podman | Rootless containers |
| **Git Tools** | git | Core version control |
| | git-lfs | Large file storage |
| | git-crypt | Transparent file encryption |
| | lazygit | TUI git client |
| | gitui | Fast TUI for git |
| | tig | Text-mode git interface |
| | git-absorb | Auto-fixup commits |
| | delta | Syntax-highlighting diff |
| | difftastic | Structural diff tool |
| | gh | GitHub CLI |
| **CLI Tools** | Yazi | TUI file manager (blazing fast) |
| | ripgrep | Fast grep replacement |
| | fd | Fast find replacement |
| | bat | cat with syntax highlighting |
| | eza | Modern ls with icons |
| | fzf | Fuzzy finder |
| | zoxide | Smart cd (learns your habits) |
| | btop | Beautiful system monitor |

#### Aliases Quick Reference

**Navigation & Files**
| Alias | Command | Description |
|-------|---------|-------------|
| `y` | `yazi` | TUI file manager |
| `files` | `dolphin .` | Open Dolphin here |
| `ls` | `eza --icons` | List with icons |
| `la` | `eza -la --icons` | List all with details |
| `lt` | `eza -lT --level=2` | Tree view |
| `cat` | `bat` | Syntax highlighted cat |

**Editors**
| Alias | Command | Description |
|-------|---------|-------------|
| `v` | `nvim` | Neovim |
| `code` | `code --no-sandbox` | VS Code |
| `k` | `kate` | Kate editor |

**Git - Core**
| Alias | Command | Description |
|-------|---------|-------------|
| `gs` | `git status` | Status |
| `ga` | `git add` | Stage files |
| `gaa` | `git add --all` | Stage all |
| `gcm` | `git commit -m` | Commit with message |
| `gca` | `git commit --amend` | Amend last commit |
| `gp` | `git push` | Push |
| `gpf` | `git push --force-with-lease` | Safe force push |
| `gpl` | `git pull` | Pull |
| `gf` | `git fetch` | Fetch |
| `gfa` | `git fetch --all --prune` | Fetch all remotes |
| `gd` | `git diff` | Show diff |
| `gds` | `git diff --staged` | Staged diff |
| `gl` | `git log --oneline` | Short log |
| `gla` | `git log --all --graph` | Full graph log |

**Git - Tools**
| Alias | Command | Description |
|-------|---------|-------------|
| `lg` | `lazygit` | TUI git client |
| `gui` | `gitui` | Fast TUI for git |
| `tig` | `tig` | Text-mode interface |
| `tiga` | `tig --all` | All branches |
| `gab` | `git absorb` | Auto-fixup commits |
| `gcrypt` | `git-crypt` | Encrypt files |

**Git - Utilities**
| Alias | Command | Description |
|-------|---------|-------------|
| `gwip` | `git add -A && commit "WIP"` | Quick WIP commit |
| `gunwip` | `git reset HEAD~1` | Undo last commit |
| `gamend` | `git commit --amend --no-edit` | Amend no message |
| `gundo` | `git reset --soft HEAD~1` | Soft undo |
| `ghpr` | `gh pr create` | Create PR |
| `ghprl` | `gh pr list` | List PRs |

**Docker**
| Alias | Command | Description |
|-------|---------|-------------|
| `d` | `docker` | Docker |
| `dc` | `docker compose` | Compose |
| `dps` | `docker ps` | List containers |
| `dex` | `docker exec -it` | Exec into container |
| `dlog` | `docker logs -f` | Follow logs |

**Development**
| Alias | Command | Description |
|-------|---------|-------------|
| `py` | `python` | Python |
| `ipy` | `ipython` | IPython REPL |
| `jn` | `jupyter notebook` | Jupyter |
| `ni` | `npm install` | npm install |
| `nr` | `npm run` | npm run |
| `pnr` | `pnpm run` | pnpm run |
| `cr` | `cargo run` | Cargo run |
| `cb` | `cargo build` | Cargo build |
| `ct` | `cargo test` | Cargo test |
| `cw` | `cargo watch -x run` | Watch mode |

**VPN & Security**
| Alias | Command | Description |
|-------|---------|-------------|
| `vpnc` | `protonvpn-cli connect` | Connect VPN |
| `vpnd` | `protonvpn-cli disconnect` | Disconnect |
| `vpns` | `protonvpn-cli status` | VPN status |
| `wgup` | `wg-quick up wg0` | WireGuard up |
| `wgdown` | `wg-quick down wg0` | WireGuard down |
| `bwl` | `bw login` | Bitwarden login |
| `bwu` | `bw unlock` | Unlock vault |
| `bwsync` | `bw sync` | Sync vault |
| `bwpass` | `bw get password` | Get password |

**AI & Cloud**
| Alias | Command | Description |
|-------|---------|-------------|
| `claude` | `claude` | Claude Code CLI |
| `ai` | `claude` | Alias for Claude |
| `gemini` | `gemini` | Gemini CLI |
| `rc` | `rclone` | Cloud sync |
| `rcconfig` | `rclone config` | Setup remotes |
| `rcsync` | `rclone sync` | Sync files |

**System**
| Alias | Command | Description |
|-------|---------|-------------|
| `top` | `btop` | System monitor |
| `ps` | `procs` | Process list |
| `du` | `dust` | Disk usage |
| `ports` | `ss -tulpn` | Show open ports |
| `myip` | `curl ifconfig.me` | Public IP |

**Package Management (Arch)**
| Alias | Command | Description |
|-------|---------|-------------|
| `pacs` | `sudo pacman -S` | Install package |
| `pacu` | `sudo pacman -Syu` | System update |
| `pacr` | `sudo pacman -Rns` | Remove package |
| `yas` | `yay -S` | Install from AUR |
| `yau` | `yay -Syu` | Update all (incl. AUR) |

**Applications**
| Alias | Command | Description |
|-------|---------|-------------|
| `browser` | `brave` | Web browser |
| `notes` | `obsidian` | Note-taking |
| `music` | `spotify` | Music player |
| `mail` | `proton-mail` | Email client |
| `secrets` | `bitwarden` | Password manager |

> **Full alias list**: See `assets/desktop/shell-aliases.sh` (100+ aliases)

---

## B) What is This

### Overview

**Cloud Connect** is a comprehensive CLI toolset that provides:

1. **Desktop Sandbox** - Portable, encrypted KDE Plasma environment in Docker
2. **Cloud Connectivity** - VPN, SSH, and mount management for cloud infrastructure
3. **Bootable USB** - LUKS-encrypted portable workstation

### Problem Statement

**Scenario:** User is on an untrusted/non-safe computer (public machine, borrowed laptop, fresh install) and needs to:

1. Work in an isolated environment that doesn't touch the host system
2. Establish secure network connectivity to personal cloud infrastructure
3. Access cloud-synced files with bidirectional sync
4. Use familiar tools with personal configurations

**Solution:** A single CLI that bootstraps a secure, isolated, fully-configured workstation environment.

### Key Features

| Feature | Description |
|---------|-------------|
| **Full Desktop** | KDE Plasma with Dolphin, Konsole, Kate |
| **Encrypted** | LUKS2 AES-256 encryption for USB |
| **Development Ready** | Python, Node.js, Rust pre-installed |
| **VPN Ready** | WireGuard, OpenVPN, ProtonVPN |
| **Split Tunnel** | Cloud traffic via WireGuard, public via ProtonVPN |
| **Resource Safe** | Limited to 90% CPU/RAM to prevent crashes |
| **Portable** | Same environment everywhere |
| **Persistent** | Data survives reboots (USB mode) |
| **Cloud Sync** | rclone bisync with 40+ providers |
| **AI Ready** | Claude CLI and Gemini pre-installed |

### Use Cases

- **Fresh Machine Setup** - Instantly get your full dev environment
- **Secure Workstation** - Encrypted, isolated from host
- **Travel Computing** - Carry your desktop on USB
- **Testing/Development** - Disposable environments
- **Privacy** - ProtonVPN + encrypted storage
- **Cloud Access** - Connect to VMs via VPN with file sync

---

## C) UI Designs

### Desktop Environment

```
+---------------------------------------------------------------------------+
|  Cloud Desktop - KDE Plasma                                    [_][o][X] |
+---------------------------------------------------------------------------+
|                                                                           |
|   +---------+  +---------+  +---------+  +---------+  +---------+        |
|   |         |  |         |  |         |  |         |  |         |        |
|   | Dolphin |  | Konsole |  |  Kate   |  |  Brave  |  |Obsidian |        |
|   |         |  |         |  |         |  |         |  |         |        |
|   +---------+  +---------+  +---------+  +---------+  +---------+        |
|                                                                           |
|   +---------+  +---------+  +---------+  +---------+  +---------+        |
|   |         |  |         |  |         |  |         |  |         |        |
|   | VS Code |  | Spotify |  |  Yazi   |  | Lazygit |  | Settings|        |
|   |         |  |         |  |         |  |         |  |         |        |
|   +---------+  +---------+  +---------+  +---------+  +---------+        |
|                                                                           |
+---------------------------------------------------------------------------+
| = Applications | Files | Brave | Kate |              | Vol | Net | Clock |
+---------------------------------------------------------------------------+
```

### Terminal (Fish + Starship)

```
+-- diegonmarcos  ~/Projects/myapp  main !?  v1.2.0
+-> cargo build --release
   Compiling myapp v1.2.0
    Finished release [optimized] target(s) in 2.34s

+-- diegonmarcos  ~/Projects/myapp  main  took 2s
+-> _
```

### Cloud Connect TUI

```
+==============================================================================+
|                         CLOUD CONNECT v2.0                                   |
|                    VPN - SSH - Mount - Vault Manager                         |
+==============================================================================+
|                                                                              |
|                              INTERNET                                        |
|                                 |                                            |
|         +-------------------+---+---+-------------------+                    |
|         |                   |       |                   |                    |
|         v                   v       v                   v                    |
|   +-----------+      +-----------+      +-----------+      +-----------+     |
|   |Oracle Dev |      |  GCP Hub  |      |Oracle Web |      |Oracle Svc |     |
|   |84.235.234 |      |34.55.55   |      |130.110.251|      |129.151.228|     |
|   +-----------+      +-----------+      +-----------+      +-----------+     |
|         |                   |                   |                   |        |
|         +-------------------+-------------------+-------------------+        |
|                    WireGuard VPN (10.0.0.0/24)                               |
|                         @ CONNECTED (split)                                  |
|                                 |                                            |
|                           +-----------+                                      |
|                           | 10.0.0.5  |                                      |
|                           |   LOCAL   |                                      |
|                           +-----------+                                      |
|                                                                              |
+==============================================================================+
|  VM STATUS                                                                   |
|  ------------------------------------------------------------------------   |
|  VM              WG IP        Public IP        WG      Public    Mount      |
|  GCP Hub         10.0.0.1     34.55.55.234     12ms    45ms      @          |
|  Oracle Dev      10.0.0.2     84.235.234.87    18ms    52ms      @          |
|  Oracle Web      10.0.0.3     130.110.251.193  15ms    48ms      o          |
|  Oracle Services 10.0.0.4     129.151.228.66   20ms    55ms      @          |
|                                                                              |
+==============================================================================+
|  VPN: @ UP (split) | Transfer: v 1.2MB ^ 456KB | Mounts: 3/4 | Vault: Open  |
+==============================================================================+
|                                                                              |
|  +--------------+  +--------------+  +--------------+  +--------------+      |
|  | [V] VPN      |  | [S] SSH      |  | [M] Mount    |  | [B] Vault    |      |
|  |              |  |              |  |              |  |              |      |
|  |  v) up       |  |  1) gcp      |  |  m) all      |  |  b) open     |      |
|  |  d) down     |  |  2) dev      |  |  u) unmount  |  |  l) lock     |      |
|  |  t) toggle   |  |  3) web      |  |  a) pub IP   |  |  s) sync     |      |
|  |  f) full     |  |  4) services |  |              |  |              |      |
|  |  p) split    |  |              |  |  1-4) indiv  |  |              |      |
|  +--------------+  +--------------+  +--------------+  +--------------+      |
|                                                                              |
|  [X] Setup        [R] Refresh       [?] Help        [Q] Quit                 |
|                                                                              |
+==============================================================================+

 >
```

### TUI Keybindings

| Key | Action |
|-----|--------|
| `v` | VPN up |
| `d` / `V` | VPN down |
| `t` | Toggle tunnel (split/full) |
| `f` | Full tunnel |
| `p` | Split tunnel |
| `1-4` | SSH to VM |
| `m` | Mount all |
| `u` / `M` | Unmount all |
| `b` | Vault menu |
| `x` | Setup menu |
| `r` | Refresh |
| `?` | Help |
| `q` | Quit |

### CLI Interface

```bash
$ cloud setup sandbox create mydesktop

Creating Cloud Desktop Sandbox

  Name:      cloud-sandbox-mydesktop
  Desktop:   KDE Plasma
  Apps:      Dolphin, Konsole, Kate, Brave, Obsidian
  User:      diegonmarcos
  Password:  changeme (must change on first login)

  Resource Limits (90% of system):
    Memory:  14g
    Swap:    14g (equal to RAM)
    CPUs:    7.2

Setting up Docker KDE Desktop...
Building Docker image (this may take 10-15 minutes)...
Starting container with resource limits...

======================================================================
Success: Sandbox 'mydesktop' created!
======================================================================

Desktop access:
  Enter shell: cloud setup sandbox enter mydesktop
  Full desktop: The KDE desktop is running with X11 forwarding

First login:
  User:     diegonmarcos
  Password: changeme (you MUST change this)
```

---

## D) Architecture

### System Architecture

```
+---------------------------------------------------------------------------+
|                           HOST SYSTEM                                      |
|  +---------------------------------------------------------------------+  |
|  |                        DOCKER ENGINE                                |  |
|  |  +---------------------------------------------------------------+  |  |
|  |  |              CLOUD DESKTOP CONTAINER                          |  |  |
|  |  |  +---------------------------------------------------------+  |  |  |
|  |  |  |                  KDE PLASMA                             |  |  |  |
|  |  |  |  +----------+ +----------+ +----------+                 |  |  |  |
|  |  |  |  | Dolphin  | | Konsole  | |   Kate   |                 |  |  |  |
|  |  |  |  +----------+ +----------+ +----------+                 |  |  |  |
|  |  |  |  +----------+ +----------+ +----------+                 |  |  |  |
|  |  |  |  |  Brave   | | Obsidian | | VS Code  |                 |  |  |  |
|  |  |  |  +----------+ +----------+ +----------+                 |  |  |  |
|  |  |  +---------------------------------------------------------+  |  |  |
|  |  |  +---------------------------------------------------------+  |  |  |
|  |  |  |              DEVELOPMENT TOOLS                          |  |  |  |
|  |  |  |  Python | Node.js | Rust | Go | Docker | Git            |  |  |  |
|  |  |  +---------------------------------------------------------+  |  |  |
|  |  |  +---------------------------------------------------------+  |  |  |
|  |  |  |                 VPN / NETWORK                           |  |  |  |
|  |  |  |  WireGuard | ProtonVPN | OpenVPN | rclone               |  |  |  |
|  |  |  +---------------------------------------------------------+  |  |  |
|  |  +---------------------------------------------------------------+  |  |
|  |                              |                                      |  |
|  |                    +---------v---------+                            |  |
|  |                    |   Docker Volume   |                            |  |
|  |                    |  (Persistent Data)|                            |  |
|  |                    +-------------------+                            |  |
|  +---------------------------------------------------------------------+  |
|                                 |                                         |
|            +--------------------+--------------------+                    |
|            |                    |                    |                    |
|       +----v----+         +-----v-----+        +----v----+               |
|       |  X11    |         |  /dev/dri |        | /dev/snd|               |
|       | Socket  |         |   (GPU)   |        | (Audio) |               |
|       +---------+         +-----------+        +---------+               |
+---------------------------------------------------------------------------+
```

### Network Architecture (Split Tunnel)

```
                          SANDBOX
                             |
              +--------------+---------------+
              |                              |
              v                              v
     +----------------+            +----------------+
     |  WireGuard VPN |            |   Proton VPN   |
     |  (Cloud Infra) |            |  (Free Tier)   |
     +-------+--------+            +-------+--------+
             |                              |
             v                              v
     +----------------+            +----------------+
     |  Cloud VMs     |            |  Public        |
     |  - GCP Hub     |            |  Internet      |
     |  - OCI Flex    |            |  (Browsing)    |
     |  - OCI Micros  |            |                |
     +----------------+            +----------------+

     Routes:                       Routes:
     - 10.0.0.0/24 (WG)           - 0.0.0.0/0 (default)
     - VM public IPs
     - Internal services

     DNS: Encrypted (DoH/DoT)
     Provider: Cloudflare 1.1.1.1 / Quad9
```

### Split Tunnel Routing

| Traffic Type | Route Via |
|--------------|-----------|
| `10.0.0.0/24` | WireGuard (cloud LAN) |
| `34.55.55.234/32` | WireGuard (GCP Hub) |
| `84.235.234.87/32` | WireGuard (OCI Flex) |
| `130.110.251.193/32` | WireGuard (OCI Mail) |
| `129.151.228.66/32` | WireGuard (OCI Analytics) |
| `*.diegonmarcos.com` | WireGuard (services) |
| `192.168.0.0/16` | Direct (local LAN) |
| `0.0.0.0/0` | Proton VPN (public internet) |

### USB Boot Architecture

```
+---------------------------------------------------------------------------+
|                         USB DRIVE (16GB+)                                  |
+---------------------------------------------------------------------------+
|                                                                            |
|  +--------------+  +--------------+  +----------------------------------+ |
|  |  Partition 1 |  |  Partition 2 |  |         Partition 3              | |
|  |    (EFI)     |  |  (Arch ISO)  |  |    (LUKS Encrypted)              | |
|  |    512MB     |  |    2GB       |  |      Remaining Space             | |
|  |   FAT32      |  |   ISO9660    |  |                                  | |
|  |              |  |              |  |  +----------------------------+  | |
|  |  +--------+  |  |  +--------+  |  |  |    LUKS2 Container         |  | |
|  |  | Boot   |  |  |  | Arch   |  |  |  |  +----------------------+  |  | |
|  |  | Loader |  |  |  | Linux  |  |  |  |  |   EXT4 Filesystem    |  |  | |
|  |  |        |  |  |  | Live   |  |  |  |  |                      |  |  | |
|  |  |systemd |  |  |  |        |  |  |  |  |  /docker/            |  |  | |
|  |  | -boot  |  |  |  |        |  |  |  |  |  /home/              |  |  | |
|  |  +--------+  |  |  +--------+  |  |  |  |  /persistence.conf   |  |  | |
|  +--------------+  +--------------+  |  |  +----------------------+  |  | |
|                                      |  +----------------------------+  | |
|                                      +----------------------------------+ |
+---------------------------------------------------------------------------+

Boot Flow:
+---------+    +---------+    +---------+    +---------+    +---------+
|  UEFI   |--->|  Boot   |--->|  LUKS   |--->| Mount   |--->| Docker  |
|  Boot   |    | Loader  |    | Unlock  |    | Persist |    | Desktop |
+---------+    +---------+    +---------+    +---------+    +---------+
```

### Component Flow

```
+----------------------------------------------------------------------+
|                        CLOUD CONNECT CLI                              |
|                         (Rust Binary)                                 |
+----------------------------------+-----------------------------------+
                                   |
                +------------------+------------------+
                |                  |                  |
                v                  v                  v
        +-----------+      +-----------+      +-----------+
        |   Setup   |      |  Connect  |      |   Status  |
        |  Module   |      |  Module   |      |  Module   |
        +-----+-----+      +-----+-----+      +-----------+
              |                  |
    +---------+---------+        |
    |         |         |        |
    v         v         v        v
+-------+ +-------+ +-------+ +-------+
|Sandbox| |  USB  | | Apps  | |  VPN  |
|Module | |Module | |Module | |Module |
+---+---+ +---+---+ +---+---+ +---+---+
    |         |         |         |
    v         v         v         v
+-------+ +-------+ +-------+ +-------+
|Docker | | LUKS  | |Pacman | |WireG- |
|Compose| |Encrypt| |  AUR  | | uard  |
+-------+ +-------+ +-------+ +-------+
```

---

## E) Stack and Resource Usage

### Technology Stack

| Layer | Technology |
|-------|------------|
| **CLI** | Rust, Clap, Tokio |
| **Container** | Docker, Docker Compose |
| **Desktop** | KDE Plasma, X11 |
| **Base OS** | Arch Linux |
| **Encryption** | LUKS2, AES-256-XTS |
| **VPN** | WireGuard, OpenVPN |
| **Shell** | Fish, Zsh, Starship |

### Download & Storage Requirements

| Component | Size | RAM Idle | RAM Active | Download (50Mbps) | Build Time |
|-----------|------|----------|------------|-------------------|------------|
| **Base System** |
| Arch Linux base | 400 MB | 50 MB | 50 MB | 1 min | 5 sec |
| System utilities | 200 MB | 20 MB | 30 MB | 32 sec | 3 sec |
| **Display** |
| Xorg + drivers | 300 MB | 100 MB | 150 MB | 48 sec | 5 sec |
| **KDE Plasma** |
| Plasma Desktop | 800 MB | 400 MB | 600 MB | 2 min | 10 sec |
| KDE Apps | 400 MB | 50 MB | 200 MB | 1 min | 5 sec |
| Yakuake | 20 MB | 30 MB | 50 MB | 3 sec | 1 sec |
| **Fonts** |
| All fonts | 200 MB | 10 MB | 10 MB | 32 sec | 2 sec |
| **Audio** |
| PipeWire stack | 50 MB | 30 MB | 50 MB | 8 sec | 2 sec |
| **Networking & Cloud** |
| WireGuard + OpenVPN | 50 MB | 10 MB | 20 MB | 8 sec | 2 sec |
| rclone | 40 MB | 20 MB | 100 MB | 6 sec | 2 sec |
| **AI Tools** |
| Claude CLI | 50 MB | 50 MB | 150 MB | 8 sec | 5 sec |
| Gemini SDK | 30 MB | 30 MB | 100 MB | 5 sec | 3 sec |
| **Shells** |
| Fish + Zsh + plugins | 30 MB | 20 MB | 30 MB | 5 sec | 2 sec |
| Starship prompt | 5 MB | 5 MB | 5 MB | 1 sec | 1 sec |
| **File Managers** |
| Yazi | 10 MB | 15 MB | 30 MB | 2 sec | 1 sec |
| Dolphin | 50 MB | 80 MB | 150 MB | 8 sec | 2 sec |
| **Python** |
| Python + pip | 100 MB | 30 MB | 50 MB | 16 sec | 3 sec |
| NumPy + Pandas | 150 MB | 100 MB | 500 MB | 24 sec | 30 sec |
| Jupyter | 200 MB | 200 MB | 400 MB | 32 sec | 20 sec |
| **Node.js** |
| Node + npm | 100 MB | 50 MB | 100 MB | 16 sec | 3 sec |
| pnpm + yarn | 50 MB | 20 MB | 50 MB | 8 sec | 5 sec |
| TypeScript + tools | 150 MB | 150 MB | 400 MB | 24 sec | 15 sec |
| **Rust** |
| Rustup + toolchain | 500 MB | 50 MB | 100 MB | 1 min 20 sec | 30 sec |
| rust-analyzer | 200 MB | 500 MB | 1500 MB | 32 sec | 3 sec |
| Cargo tools | 300 MB | 50 MB | 100 MB | 48 sec | 3-5 min |
| **Other Languages** |
| Go | 150 MB | 50 MB | 200 MB | 24 sec | 5 sec |
| GCC + Clang + LLVM | 400 MB | 100 MB | 500 MB | 1 min | 10 sec |
| **Containers** |
| Docker + Compose | 150 MB | 100 MB | 200 MB | 24 sec | 5 sec |
| Podman + Buildah | 100 MB | 80 MB | 150 MB | 16 sec | 3 sec |
| **AUR Apps** |
| Brave Browser | 300 MB | 300 MB | 2000 MB | 48 sec | 2-3 min |
| VS Code | 400 MB | 400 MB | 1500 MB | 1 min | 1-2 min |
| Obsidian | 250 MB | 200 MB | 800 MB | 40 sec | 1-2 min |
| ProtonVPN CLI | 50 MB | 30 MB | 50 MB | 8 sec | 30 sec |
| Proton Mail | 150 MB | 200 MB | 500 MB | 24 sec | 1-2 min |
| Bitwarden | 200 MB | 150 MB | 400 MB | 32 sec | 1-2 min |
| Spotify | 150 MB | 150 MB | 400 MB | 24 sec | 1-2 min |
| **Git Tools** |
| git + git-lfs | 50 MB | 20 MB | 50 MB | 8 sec | 2 sec |
| git-crypt | 2 MB | 5 MB | 10 MB | 1 sec | 1 sec |
| lazygit | 15 MB | 30 MB | 80 MB | 2 sec | 1 sec |
| gitui | 10 MB | 20 MB | 50 MB | 2 sec | 1 sec |
| tig | 3 MB | 10 MB | 20 MB | 1 sec | 1 sec |
| git-absorb | 5 MB | 10 MB | 20 MB | 1 sec | 1 sec |
| delta | 8 MB | 15 MB | 30 MB | 1 sec | 1 sec |
| difftastic | 15 MB | 20 MB | 40 MB | 2 sec | 1 sec |
| gh (GitHub CLI) | 30 MB | 30 MB | 60 MB | 5 sec | 2 sec |

### Totals

| Metric | Value |
|--------|-------|
| **Total Download Size** | ~7.1 GB |
| **Download Time (50 Mbps)** | ~20-23 minutes |
| **Docker Image Size** | ~8-9 GB |
| **Build Time** | ~15-25 minutes |

### Runtime Resource Usage

| Scenario | RAM Usage | CPU Usage |
|----------|-----------|-----------|
| **Idle Desktop** (KDE only) | 800 MB - 1.2 GB | 2-5% |
| **Light Use** (terminal, file manager) | 1.5 - 2 GB | 5-10% |
| **Development** (VS Code + terminal) | 2 - 4 GB | 10-30% |
| **Heavy** (VS Code + Brave + Rust compile) | 4 - 8 GB | 50-90% |
| **Maximum** (all apps + compilation) | 8 - 12 GB | 90%+ |

### System Requirements

| Resource | Minimum | Recommended | Optimal |
|----------|---------|-------------|---------|
| **RAM** | 4 GB | 8 GB | 16+ GB |
| **CPU** | 2 cores | 4 cores | 8+ cores |
| **Storage** | 16 GB | 32 GB | 64+ GB |
| **USB Speed** | USB 2.0 | USB 3.0 | USB 3.1+ |

### Resource Limits

The container is configured to never exceed:

| Resource | Limit |
|----------|-------|
| **CPU** | 90% of host CPUs |
| **Memory** | 90% of host RAM |
| **Swap** | Equal to memory limit |

This prevents the desktop from crashing the host system.

---

## F) Technical Specification

### Module Architecture

```
cloud_connect/
|-- Cargo.toml                  # Workspace definition
|
|-- crates/
|   |
|   |-- connect_lib/            # CORE LIBRARY
|   |   +-- src/
|   |       |-- lib.rs          # Public API exports
|   |       |
|   |       |-- sandbox/        # Docker isolation
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # SandboxConfig, SandboxStatus
|   |       |   |-- container.rs    # create(), enter(), stop(), destroy()
|   |       |   |-- image.rs        # build(), pull(), list()
|   |       |   +-- volumes.rs      # mount_volume(), unmount_volume()
|   |       |
|   |       |-- network/        # Secure networking
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # NetworkConfig, VpnStatus, DnsConfig
|   |       |   |-- wireguard.rs    # wg_up(), wg_down(), wg_status()
|   |       |   |-- proton.rs       # proton_up(), proton_down()
|   |       |   |-- dns.rs          # set_dns(), test_dns()
|   |       |   +-- routing.rs      # enable_split(), disable_split()
|   |       |
|   |       |-- sync/           # File synchronization
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # MountConfig, BisyncPair
|   |       |   |-- fuse.rs         # mount(), unmount(), list_mounts()
|   |       |   |-- bisync.rs       # run_bisync(), dry_run()
|   |       |   +-- rclone.rs       # install_rclone(), import_config()
|   |       |
|   |       |-- tools/          # Application setup
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # ToolConfig, InstallResult
|   |       |   |-- installer.rs    # install_package(), PackageManager
|   |       |   |-- brave.rs        # install_brave(), apply_config()
|   |       |   |-- obsidian.rs     # install_obsidian(), apply_config()
|   |       |   |-- konsole.rs      # install_konsole(), setup_shell()
|   |       |   |-- kate.rs         # install_kate(), apply_config()
|   |       |   +-- dolphin.rs      # install_dolphin(), apply_config()
|   |       |
|   |       |-- bootstrap/      # Orchestration
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # BootstrapConfig, BootstrapProgress
|   |       |   |-- sequence.rs     # run_bootstrap()
|   |       |   +-- preflight.rs    # run_preflight_checks()
|   |       |
|   |       |-- config/         # Configuration management
|   |       |   |-- mod.rs
|   |       |   |-- types.rs    # AppConfig
|   |       |   |-- loader.rs       # load_config(), save_config()
|   |       |   +-- paths.rs        # get_config_dir()
|   |       |
|   |       +-- error.rs        # CloudError, Result type alias
|   |
|   +-- connect_cli/            # CLI BINARY
|       +-- src/
|           |-- main.rs         # Entry point, clap setup
|           |-- commands/       # Command handlers
|           |   |-- mod.rs
|           |   |-- sandbox.rs
|           |   |-- network.rs
|           |   |-- sync.rs
|           |   |-- tools.rs
|           |   +-- bootstrap.rs
|           +-- output/         # CLI formatting
|               |-- mod.rs
|               |-- table.rs
|               |-- progress.rs
|               +-- colors.rs
```

### Full Command Tree

```
cloud-connect
|-- sandbox
|   |-- create [--name <name>]
|   |-- enter [--name <name>]
|   |-- stop [--name <name>]
|   |-- destroy [--name <name>]
|   |-- list
|   +-- status
|
|-- network
|   |-- wg {up|down|status}
|   |-- proton {up|down|status|servers}
|   |-- dns {set <provider>|status|test}
|   |-- split {enable|disable|status}
|   +-- status
|
|-- sync
|   |-- mount [<remote>]
|   |-- unmount [<remote>]
|   |-- mounts
|   |-- rclone {install|config|remotes}
|   +-- bisync {run|status|dry-run}
|
|-- tools
|   |-- install [<tool>]
|   |-- brave {install|config|addons}
|   |-- obsidian {install|config}
|   |-- konsole {install|config}
|   |-- kate {install|config}
|   |-- dolphin {install|config}
|   +-- status
|
|-- bootstrap [--yes] [--skip <module>] [--only <module>]
|   +-- status
|
+-- status                    # Overall system status
```

### Configuration File

**Location:** `~/.config/cloud-connect/config.toml`

```toml
[general]
verbose = false
sandbox_name = "secure-workstation"

# SANDBOX
[sandbox]
image = "cloud-connect-sandbox:latest"
network_mode = "host"
privileged = true
x11_forward = true

[sandbox.volumes]
"/tmp/.X11-unix" = "/tmp/.X11-unix"
"~/.config/cloud-connect" = "/home/sandbox/.config/cloud-connect"

# NETWORK
[network.wireguard]
interface = "wg0"
config_path = "~/.config/wireguard/wg0.conf"
endpoint = "34.55.55.234:51820"
keepalive = 25

[network.proton]
username = "diego"
protocol = "udp"

[network.dns]
provider = "cloudflare"   # cloudflare | quad9 | google
protocol = "doh"          # doh | dot

[network.split_tunnel]
enabled = true
wireguard_routes = [
    "10.0.0.0/24",
    "34.55.55.234/32",
    "84.235.234.87/32",
    "130.110.251.193/32",
    "129.151.228.66/32",
]
local_bypass = [
    "192.168.0.0/16",
    "172.16.0.0/12",
]

# SYNC
[sync.rclone]
config_source = "LOCAL_KEYS/configs/rclone/rclone.conf"

[[sync.mounts]]
name = "gcp-home"
remote = "sftp-gcp"
remote_path = "/home/diego"
local_path = "~/mnt/cloud/gcp"
type = "sshfs"

[[sync.bisync]]
name = "obsidian-vault"
path1 = "~/Documents/Obsidian"
path2 = "gcp:/home/diego/Documents/Obsidian"
conflict_resolve = "newer"

# TOOLS
[tools.brave]
install_method = "flatpak"
profile_source = "LOCAL_KEYS/configs/browser/brave/"
extensions = [
    "cjpalhdlnbpafiamejdnhcphjbkeiagm",  # uBlock Origin
    "nngceckbapebfimnlniiiahkandclblb",  # Bitwarden
    "dbepggeogbaibhgnhhndojpepiihcmeb",  # Vimium
    "eimadpbcbfnmbkopoojfekhnkhdbieeh",  # Dark Reader
]

[tools.obsidian]
install_method = "flatpak"
vault_path = "~/mnt/cloud/gcp/Documents/Obsidian"
config_source = "LOCAL_KEYS/configs/obsidian/"
plugins = ["obsidian-git", "dataview", "templater", "calendar", "excalidraw"]

[tools.konsole]
install_method = "pacman"
profile_source = "LOCAL_KEYS/configs/konsole/"

[tools.shell]
default = "fish"
fish_config = "LOCAL_KEYS/configs/linux/fish/"
starship_config = "LOCAL_KEYS/configs/linux/starship.toml"

[tools.kate]
install_method = "pacman"
config_source = "LOCAL_KEYS/configs/kate/"

[tools.dolphin]
install_method = "pacman"
config_source = "LOCAL_KEYS/configs/dolphin/"
```

### Security Model

#### Threat Model

| Threat | Mitigation |
|--------|------------|
| Host keylogger | Docker isolation, no host shell access |
| Network sniffing | Encrypted DNS + VPN for all traffic |
| Local file access | Sandbox volumes limited to necessary paths |
| Credential theft | Keys stay in LOCAL_KEYS, accessed via mount |
| DNS leaks | DoH/DoT enforced, leak test on startup |
| Traffic analysis | Split tunnel hides cloud infrastructure |

#### Security Layers

```
Layer 1: SANDBOX ISOLATION
+-- Docker container boundaries
+-- Limited volume mounts
+-- No privileged host access (except network)
+-- Ephemeral by default

Layer 2: NETWORK ENCRYPTION
+-- WireGuard (cloud traffic) - ChaCha20-Poly1305
+-- Proton VPN (public traffic) - AES-256-GCM
+-- DNS over HTTPS/TLS
+-- No plaintext DNS queries

Layer 3: SPLIT TUNNEL ROUTING
+-- Cloud infra traffic -> WireGuard
+-- Public traffic -> Proton VPN
+-- Local traffic -> Direct
+-- No traffic leaks to ISP

Layer 4: CREDENTIAL SECURITY
+-- SSH keys in LOCAL_KEYS only
+-- No secrets in container image
+-- Secrets mounted read-only
+-- No persistent credential storage
```

### Rust Dependencies

```toml
[dependencies]
# Async
tokio = { version = "1", features = ["full", "process"] }

# CLI
clap = { version = "4", features = ["derive", "cargo", "env"] }

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"

# Terminal UI
tabled = "0.17"
owo-colors = "4"
indicatif = "0.17"
console = "0.15"

# Paths
dirs = "6"

# Process execution
which = "7"

# Error handling
anyhow = "1"
thiserror = "2"
```

---

## G) Roadmap

### Phase 1: Core Foundation (Current)

- [x] Docker image with KDE Plasma
- [x] Full development stack (Python, Node, Rust, Go)
- [x] Shell configuration (Fish, Zsh, Starship)
- [x] Git tools and aliases
- [x] AI tools (Claude, Gemini)
- [x] Cloud sync (rclone)
- [x] Auto-clone repositories
- [ ] Rust CLI project structure
- [ ] CLI parser (clap)
- [ ] Config loader (TOML)
- [ ] Error handling

### Phase 2: Sandbox Module

- [ ] Container lifecycle (create/enter/stop/destroy)
- [ ] Volume management
- [ ] X11 forwarding setup
- [ ] Resource limit configuration
- [ ] First-run password change

### Phase 3: USB Module

- [ ] ISO download and verification
- [ ] Partition creation (EFI, ISO, LUKS)
- [ ] LUKS encryption setup
- [ ] Persistence configuration
- [ ] Boot loader installation

### Phase 4: Network Module

- [ ] WireGuard wrapper
- [ ] Proton VPN integration
- [ ] Encrypted DNS setup (DoH/DoT)
- [ ] Split tunnel routing
- [ ] Connection status monitoring

### Phase 5: Sync Module

- [ ] rclone installation and config import
- [ ] SSHFS/FUSE mount management
- [ ] Bisync configuration
- [ ] Mount status tracking
- [ ] Auto-reconnect on disconnect

### Phase 6: Tools Module

- [ ] Package installation abstraction
- [ ] Brave setup + config import + extensions
- [ ] Obsidian setup + plugins
- [ ] Konsole + shell setup
- [ ] Kate + Dolphin setup

### Phase 7: Bootstrap Orchestration

- [ ] Preflight checks
- [ ] Sequential module execution
- [ ] Progress tracking with indicatif
- [ ] Verification suite
- [ ] Resume from failure

### Phase 8: TUI Mode

- [ ] Interactive menu system
- [ ] Network topology diagram
- [ ] VM status table
- [ ] VPN/Mount status bar
- [ ] Keybinding navigation

---

## H) References & Links

### Core Technologies

| Technology | Repository | Documentation |
|------------|------------|---------------|
| **Arch Linux** | [gitlab.archlinux.org](https://gitlab.archlinux.org/archlinux) | [wiki.archlinux.org](https://wiki.archlinux.org/) |
| **KDE Plasma** | [github.com/KDE](https://github.com/KDE) | [kde.org/plasma-desktop](https://kde.org/plasma-desktop/) |
| **Docker** | [github.com/docker](https://github.com/docker) | [docs.docker.com](https://docs.docker.com/) |
| **Rust** | [github.com/rust-lang/rust](https://github.com/rust-lang/rust) | [rust-lang.org](https://www.rust-lang.org/) |

### Desktop Applications

| Application | Repository | Website |
|-------------|------------|---------|
| **Dolphin** | [github.com/KDE/dolphin](https://github.com/KDE/dolphin) | [apps.kde.org/dolphin](https://apps.kde.org/dolphin/) |
| **Konsole** | [github.com/KDE/konsole](https://github.com/KDE/konsole) | [apps.kde.org/konsole](https://apps.kde.org/konsole/) |
| **Kate** | [github.com/KDE/kate](https://github.com/KDE/kate) | [apps.kde.org/kate](https://apps.kde.org/kate/) |
| **Yakuake** | [github.com/KDE/yakuake](https://github.com/KDE/yakuake) | [apps.kde.org/yakuake](https://apps.kde.org/yakuake/) |
| **Brave** | [github.com/brave/brave-browser](https://github.com/brave/brave-browser) | [brave.com](https://brave.com/) |
| **Obsidian** | Closed Source | [obsidian.md](https://obsidian.md/) |
| **VS Code** | [github.com/microsoft/vscode](https://github.com/microsoft/vscode) | [code.visualstudio.com](https://code.visualstudio.com/) |
| **Spotify** | Closed Source | [spotify.com](https://www.spotify.com/) |
| **Bitwarden** | [github.com/bitwarden](https://github.com/bitwarden) | [bitwarden.com](https://bitwarden.com/) |

### Development Tools

| Tool | Repository | Documentation |
|------|------------|---------------|
| **Python** | [github.com/python/cpython](https://github.com/python/cpython) | [python.org](https://www.python.org/) |
| **Node.js** | [github.com/nodejs/node](https://github.com/nodejs/node) | [nodejs.org](https://nodejs.org/) |
| **Rust** | [github.com/rust-lang/rust](https://github.com/rust-lang/rust) | [rust-lang.org](https://www.rust-lang.org/) |
| **Go** | [github.com/golang/go](https://github.com/golang/go) | [go.dev](https://go.dev/) |
| **Poetry** | [github.com/python-poetry/poetry](https://github.com/python-poetry/poetry) | [python-poetry.org](https://python-poetry.org/) |
| **pnpm** | [github.com/pnpm/pnpm](https://github.com/pnpm/pnpm) | [pnpm.io](https://pnpm.io/) |
| **Cargo** | [github.com/rust-lang/cargo](https://github.com/rust-lang/cargo) | [doc.rust-lang.org/cargo](https://doc.rust-lang.org/cargo/) |

### CLI Tools

| Tool | Repository | Description |
|------|------------|-------------|
| **Fish Shell** | [github.com/fish-shell/fish-shell](https://github.com/fish-shell/fish-shell) | Friendly interactive shell |
| **Zsh** | [github.com/zsh-users/zsh](https://github.com/zsh-users/zsh) | Z shell |
| **Starship** | [github.com/starship/starship](https://github.com/starship/starship) | Cross-shell prompt |
| **Yazi** | [github.com/sxyazi/yazi](https://github.com/sxyazi/yazi) | Terminal file manager |
| **Neovim** | [github.com/neovim/neovim](https://github.com/neovim/neovim) | Hyperextensible text editor |
| **lazygit** | [github.com/jesseduffield/lazygit](https://github.com/jesseduffield/lazygit) | Terminal UI for git |
| **ripgrep** | [github.com/BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) | Fast grep replacement |
| **fd** | [github.com/sharkdp/fd](https://github.com/sharkdp/fd) | Fast find replacement |
| **bat** | [github.com/sharkdp/bat](https://github.com/sharkdp/bat) | Cat with syntax highlighting |
| **eza** | [github.com/eza-community/eza](https://github.com/eza-community/eza) | Modern ls replacement |
| **fzf** | [github.com/junegunn/fzf](https://github.com/junegunn/fzf) | Fuzzy finder |
| **zoxide** | [github.com/ajeetdsouza/zoxide](https://github.com/ajeetdsouza/zoxide) | Smarter cd command |
| **btop** | [github.com/aristocratos/btop](https://github.com/aristocratos/btop) | Resource monitor |
| **delta** | [github.com/dandavison/delta](https://github.com/dandavison/delta) | Syntax-highlighting pager |
| **rclone** | [github.com/rclone/rclone](https://github.com/rclone/rclone) | Cloud storage sync |

### VPN & Security

| Tool | Repository | Website |
|------|------------|---------|
| **WireGuard** | [github.com/WireGuard](https://github.com/WireGuard) | [wireguard.com](https://www.wireguard.com/) |
| **ProtonVPN** | [github.com/ProtonVPN](https://github.com/ProtonVPN) | [protonvpn.com](https://protonvpn.com/) |
| **OpenVPN** | [github.com/OpenVPN](https://github.com/OpenVPN) | [openvpn.net](https://openvpn.net/) |
| **LUKS** | [gitlab.com/cryptsetup/cryptsetup](https://gitlab.com/cryptsetup/cryptsetup) | [cryptsetup](https://gitlab.com/cryptsetup/cryptsetup) |

### Container Tools

| Tool | Repository | Documentation |
|------|------------|---------------|
| **Docker** | [github.com/docker](https://github.com/docker) | [docs.docker.com](https://docs.docker.com/) |
| **Docker Compose** | [github.com/docker/compose](https://github.com/docker/compose) | [docs.docker.com/compose](https://docs.docker.com/compose/) |
| **Podman** | [github.com/containers/podman](https://github.com/containers/podman) | [podman.io](https://podman.io/) |
| **Buildah** | [github.com/containers/buildah](https://github.com/containers/buildah) | [buildah.io](https://buildah.io/) |

### Rust Crates Used

| Crate | Repository | Purpose |
|-------|------------|---------|
| **clap** | [github.com/clap-rs/clap](https://github.com/clap-rs/clap) | CLI argument parsing |
| **tokio** | [github.com/tokio-rs/tokio](https://github.com/tokio-rs/tokio) | Async runtime |
| **anyhow** | [github.com/dtolnay/anyhow](https://github.com/dtolnay/anyhow) | Error handling |
| **serde** | [github.com/serde-rs/serde](https://github.com/serde-rs/serde) | Serialization |
| **owo-colors** | [github.com/jam1garner/owo-colors](https://github.com/jam1garner/owo-colors) | Terminal colors |
| **indicatif** | [github.com/console-rs/indicatif](https://github.com/console-rs/indicatif) | Progress bars |

---

## License

MIT License - See [LICENSE](LICENSE) for details.

---

## Author

**Diego Nepomuceno Marcos**
- Email: me@diegonmarcos.com
- GitHub: [@diegonmarcos](https://github.com/diegonmarcos)
