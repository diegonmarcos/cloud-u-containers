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
- [D) Architecture Diagrams](#d-architecture-diagrams)
- [E) Stack and Resource Usage](#e-stack-and-resource-usage)
- [F) References & Links](#f-references--links)

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

> ⚠️ **You MUST change the password on first login** - the system enforces this.

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
| **CLI Tools** | Yazi | TUI file manager (blazing fast) |
| | lazygit | TUI git client |
| | ripgrep | Fast grep replacement |
| | fd | Fast find replacement |
| | bat | cat with syntax highlighting |
| | eza | Modern ls with icons |
| | fzf | Fuzzy finder |
| | zoxide | Smart cd (learns your habits) |
| | btop | Beautiful system monitor |
| | delta | Git diff with syntax highlighting |

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

**Git**
| Alias | Command | Description |
|-------|---------|-------------|
| `gs` | `git status` | Status |
| `ga` | `git add` | Stage files |
| `gaa` | `git add --all` | Stage all |
| `gcm` | `git commit -m` | Commit with message |
| `gp` | `git push` | Push |
| `gpl` | `git pull` | Pull |
| `gd` | `git diff` | Show diff |
| `lg` | `lazygit` | TUI git client |

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

**Cloud Connect** is a Rust CLI tool that creates portable, encrypted development environments using Docker. It packages a complete KDE Plasma desktop with pre-configured development tools into either:

1. **Docker Sandbox** - Run on any Linux machine with Docker
2. **Bootable USB** - LUKS-encrypted portable workstation

### Key Features

| Feature | Description |
|---------|-------------|
| **Full Desktop** | KDE Plasma with Dolphin, Konsole, Kate |
| **Encrypted** | LUKS2 AES-256 encryption for USB |
| **Development Ready** | Python, Node.js, Rust pre-installed |
| **VPN Ready** | WireGuard, OpenVPN, ProtonVPN |
| **Resource Safe** | Limited to 90% CPU/RAM to prevent crashes |
| **Portable** | Same environment everywhere |
| **Persistent** | Data survives reboots (USB mode) |

### Use Cases

- **Fresh Machine Setup** - Instantly get your full dev environment
- **Secure Workstation** - Encrypted, isolated from host
- **Travel Computing** - Carry your desktop on USB
- **Testing/Development** - Disposable environments
- **Privacy** - ProtonVPN + encrypted storage

### Included Software

| Category | Applications |
|----------|--------------|
| **Desktop** | KDE Plasma, Dolphin, Konsole, Kate, Yakuake |
| **Browsers** | Brave |
| **Notes** | Obsidian |
| **IDE** | VS Code, Neovim |
| **Security** | Bitwarden (Desktop + CLI) |
| **VPN** | ProtonVPN, WireGuard, OpenVPN |
| **Dev - Python** | pip, poetry, numpy, pandas, jupyter |
| **Dev - Node** | npm, pnpm, yarn, typescript |
| **Dev - Rust** | rustup, cargo, rust-analyzer |
| **Dev - Other** | Go, Lua, Ruby, GCC, Clang |
| **Containers** | Docker, Podman |
| **CLI Tools** | yazi, lazygit, ripgrep, fzf, bat, eza |

---

## C) UI Designs

### Desktop Environment

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Cloud Desktop - KDE Plasma                                    [_][□][X]│
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
│   │         │  │         │  │         │  │         │  │         │      │
│   │ Dolphin │  │ Konsole │  │  Kate   │  │  Brave  │  │Obsidian │      │
│   │         │  │         │  │         │  │         │  │         │      │
│   └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘      │
│                                                                         │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
│   │         │  │         │  │         │  │         │  │         │      │
│   │ VS Code │  │ Spotify │  │  Yazi   │  │ Lazygit │  │ Settings│      │
│   │         │  │         │  │         │  │         │  │         │      │
│   └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘      │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│ ☰ Applications │ 🗂 Files │ 🌐 Brave │ 📝 Kate │        │ 🔊 │ 📶 │ 🕐 │
└─────────────────────────────────────────────────────────────────────────┘
```

### Terminal (Fish + Starship)

```
╭─  diegonmarcos  ~/Projects/myapp  main !?  v1.2.0
╰─❯ cargo build --release
   Compiling myapp v1.2.0
    Finished release [optimized] target(s) in 2.34s

╭─  diegonmarcos  ~/Projects/myapp  main  took 2s
╰─❯ _
```

### Yazi File Manager

```
┌─ /home/diegonmarcos ─────────────────────────────────────────────────────┐
│  ..                                                                      │
│   Documents/                                              <DIR>         │
│   Downloads/                                              <DIR>         │
│   Projects/                                               <DIR>         │
│   .config/                                                <DIR>         │
│   .bashrc                                                 4.2K         │
│   .zshrc                                                  3.1K         │
├──────────────────────────────────────────────────────────────────────────┤
│ [q]uit [h]elp [o]pen [y]ank [d]elete [r]ename [/]search                 │
└──────────────────────────────────────────────────────────────────────────┘
```

### CLI Interface

```
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

══════════════════════════════════════════════════════════
Success: Sandbox 'mydesktop' created!
══════════════════════════════════════════════════════════

Desktop access:
  Enter shell: cloud setup sandbox enter mydesktop
  Full desktop: The KDE desktop is running with X11 forwarding

First login:
  User:     diegonmarcos
  Password: changeme (you MUST change this)
```

---

## D) Architecture Diagrams

### System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           HOST SYSTEM                                   │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                        DOCKER ENGINE                              │  │
│  │  ┌─────────────────────────────────────────────────────────────┐  │  │
│  │  │              CLOUD DESKTOP CONTAINER                        │  │  │
│  │  │  ┌─────────────────────────────────────────────────────┐    │  │  │
│  │  │  │                  KDE PLASMA                         │    │  │  │
│  │  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │    │  │  │
│  │  │  │  │ Dolphin  │ │ Konsole  │ │   Kate   │            │    │  │  │
│  │  │  │  └──────────┘ └──────────┘ └──────────┘            │    │  │  │
│  │  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │    │  │  │
│  │  │  │  │  Brave   │ │ Obsidian │ │ VS Code  │            │    │  │  │
│  │  │  │  └──────────┘ └──────────┘ └──────────┘            │    │  │  │
│  │  │  └─────────────────────────────────────────────────────┘    │  │  │
│  │  │  ┌─────────────────────────────────────────────────────┐    │  │  │
│  │  │  │              DEVELOPMENT TOOLS                      │    │  │  │
│  │  │  │  Python │ Node.js │ Rust │ Go │ Docker │ Git       │    │  │  │
│  │  │  └─────────────────────────────────────────────────────┘    │  │  │
│  │  │  ┌─────────────────────────────────────────────────────┐    │  │  │
│  │  │  │                 VPN / NETWORK                       │    │  │  │
│  │  │  │  WireGuard │ ProtonVPN │ OpenVPN                    │    │  │  │
│  │  │  └─────────────────────────────────────────────────────┘    │  │  │
│  │  └─────────────────────────────────────────────────────────────┘  │  │
│  │                              │                                    │  │
│  │                    ┌─────────▼─────────┐                          │  │
│  │                    │   Docker Volume   │                          │  │
│  │                    │  (Persistent Data)│                          │  │
│  │                    └───────────────────┘                          │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                 │                                       │
│            ┌────────────────────┼────────────────────┐                  │
│            │                    │                    │                  │
│       ┌────▼────┐         ┌─────▼─────┐        ┌────▼────┐             │
│       │  X11    │         │  /dev/dri │        │ /dev/snd│             │
│       │ Socket  │         │   (GPU)   │        │ (Audio) │             │
│       └─────────┘         └───────────┘        └─────────┘             │
└─────────────────────────────────────────────────────────────────────────┘
```

### USB Boot Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         USB DRIVE (16GB+)                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────────────┐│
│  │  Partition 1 │  │  Partition 2 │  │         Partition 3            ││
│  │    (EFI)     │  │  (Arch ISO)  │  │    (LUKS Encrypted)            ││
│  │    512MB     │  │    2GB       │  │      Remaining Space           ││
│  │   FAT32      │  │   ISO9660    │  │                                ││
│  │              │  │              │  │  ┌────────────────────────┐    ││
│  │  ┌────────┐  │  │  ┌────────┐  │  │  │    LUKS2 Container     │    ││
│  │  │ Boot   │  │  │  │ Arch   │  │  │  │  ┌──────────────────┐  │    ││
│  │  │ Loader │  │  │  │ Linux  │  │  │  │  │   EXT4 Filesystem │  │    ││
│  │  │        │  │  │  │ Live   │  │  │  │  │                    │  │    ││
│  │  │systemd │  │  │  │        │  │  │  │  │  /docker/         │  │    ││
│  │  │ -boot  │  │  │  │        │  │  │  │  │  /home/           │  │    ││
│  │  └────────┘  │  │  └────────┘  │  │  │  │  /persistence.conf│  │    ││
│  └──────────────┘  └──────────────┘  │  │  └──────────────────┘  │    ││
│                                      │  └────────────────────────┘    ││
│                                      └────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘

Boot Flow:
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
│  UEFI   │───▶│  Boot   │───▶│  LUKS   │───▶│ Mount   │───▶│ Docker  │
│  Boot   │    │ Loader  │    │ Unlock  │    │ Persist │    │ Desktop │
└─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘
```

### Component Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                        CLOUD CONNECT CLI                             │
│                         (Rust Binary)                                │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
                ┌───────────────┼───────────────┐
                │               │               │
                ▼               ▼               ▼
        ┌───────────┐   ┌───────────┐   ┌───────────┐
        │   Setup   │   │  Connect  │   │   Status  │
        │  Module   │   │  Module   │   │  Module   │
        └─────┬─────┘   └─────┬─────┘   └───────────┘
              │               │
    ┌─────────┼─────────┐     │
    │         │         │     │
    ▼         ▼         ▼     ▼
┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐
│Sandbox│ │  USB  │ │ Apps  │ │  VPN  │
│Module │ │Module │ │Module │ │Module │
└───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘
    │         │         │         │
    ▼         ▼         ▼         ▼
┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐
│Docker │ │ LUKS  │ │Pacman │ │WireG- │
│Compose│ │Encrypt│ │  AUR  │ │ uard  │
└───────┘ └───────┘ └───────┘ └───────┘
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

| Component | Size | RAM Idle | RAM Active | CPU Load | Download (50Mbps) | Build Time |
|-----------|------|----------|------------|----------|-------------------|------------|
| **Base System** |
| Arch Linux base | 400 MB | 50 MB | 50 MB | Idle | 1 min | 5 sec |
| System utilities | 200 MB | 20 MB | 30 MB | Low | 32 sec | 3 sec |
| **Display** |
| Xorg + drivers | 300 MB | 100 MB | 150 MB | Low-Med | 48 sec | 5 sec |
| **KDE Plasma** |
| Plasma Desktop | 800 MB | 400 MB | 600 MB | Med | 2 min 8 sec | 10 sec |
| KDE Apps | 400 MB | 50 MB | 200 MB | Low | 1 min 4 sec | 5 sec |
| Yakuake | 20 MB | 30 MB | 50 MB | Low | 3 sec | 1 sec |
| **Fonts** |
| All fonts | 200 MB | 10 MB | 10 MB | Idle | 32 sec | 2 sec |
| **Audio** |
| PipeWire stack | 50 MB | 30 MB | 50 MB | Low | 8 sec | 2 sec |
| **Networking** |
| WireGuard + OpenVPN | 50 MB | 10 MB | 20 MB | Low | 8 sec | 2 sec |
| **Shells** |
| Fish + Zsh + plugins | 30 MB | 20 MB | 30 MB | Low | 5 sec | 2 sec |
| Starship prompt | 5 MB | 5 MB | 5 MB | Low | 1 sec | 1 sec |
| **File Managers** |
| Yazi | 10 MB | 15 MB | 30 MB | Low | 2 sec | 1 sec |
| Dolphin | 50 MB | 80 MB | 150 MB | Low | 8 sec | 2 sec |
| **Python** |
| Python + pip | 100 MB | 30 MB | 50 MB | Low | 16 sec | 3 sec |
| NumPy + Pandas | 150 MB | 100 MB | 500 MB | Med-High | 24 sec | 30 sec |
| Jupyter | 200 MB | 200 MB | 400 MB | Med | 32 sec | 20 sec |
| Other packages | 50 MB | - | varies | varies | 8 sec | 10 sec |
| **Node.js** |
| Node + npm | 100 MB | 50 MB | 100 MB | Low | 16 sec | 3 sec |
| pnpm + yarn | 50 MB | 20 MB | 50 MB | Low | 8 sec | 5 sec |
| TypeScript + ESLint | 100 MB | 100 MB | 300 MB | Med | 16 sec | 10 sec |
| Biome | 50 MB | 50 MB | 100 MB | Med | 8 sec | 5 sec |
| **Rust** |
| Rustup + toolchain | 500 MB | 50 MB | 100 MB | Low | 1 min 20 sec | 30 sec |
| rust-analyzer | 200 MB | 500 MB | 1500 MB | **High** | 32 sec | 3 sec |
| Cargo tools | 300 MB | 50 MB | 100 MB | Low | 48 sec | **3-5 min** |
| Compilation | - | 1 GB | 4 GB | **Very High** | - | varies |
| **Other Languages** |
| Go | 150 MB | 50 MB | 200 MB | Low | 24 sec | 5 sec |
| GCC + Clang + LLVM | 400 MB | 100 MB | 500 MB | Low | 1 min 4 sec | 10 sec |
| GDB + Valgrind | 100 MB | 50 MB | 500 MB | Med | 16 sec | 3 sec |
| **Containers** |
| Docker + Compose | 150 MB | 100 MB | 200 MB | Low | 24 sec | 5 sec |
| Podman + Buildah | 100 MB | 80 MB | 150 MB | Low | 16 sec | 3 sec |
| **AUR Apps** |
| **Brave Browser** | 300 MB | 300 MB | 2000 MB | **Med-High** | 48 sec | **2-3 min** |
| **VS Code** | 400 MB | 400 MB | 1500 MB | **Med-High** | 1 min 4 sec | **1-2 min** |
| **Obsidian** | 250 MB | 200 MB | 800 MB | Med | 40 sec | **1-2 min** |
| ProtonVPN CLI | 50 MB | 30 MB | 50 MB | Low | 8 sec | 30 sec |
| Proton Mail | 150 MB | 200 MB | 500 MB | Med | 24 sec | **1-2 min** |
| **Bitwarden** | 200 MB | 150 MB | 400 MB | Med | 32 sec | **1-2 min** |
| Bitwarden CLI | 20 MB | 20 MB | 50 MB | Low | 3 sec | 20 sec |
| **Spotify** | 150 MB | 150 MB | 400 MB | Med | 24 sec | **1-2 min** |
| **CLI Tools** |
| ripgrep | 5 MB | 10 MB | 20 MB | Low | 1 sec | 1 sec |
| fd | 3 MB | 10 MB | 20 MB | Low | 1 sec | 1 sec |
| bat | 6 MB | 15 MB | 30 MB | Low | 1 sec | 1 sec |
| fzf | 3 MB | 20 MB | 50 MB | Low | 1 sec | 1 sec |
| eza | 2 MB | 5 MB | 10 MB | Low | 1 sec | 1 sec |
| lazygit | 15 MB | 30 MB | 80 MB | Low | 2 sec | 1 sec |
| btop | 3 MB | 20 MB | 40 MB | Low | 1 sec | 1 sec |

### Totals

| Metric | Value |
|--------|-------|
| **Total Download Size** | ~6.7 GB |
| **Download Time (50 Mbps)** | ~19-21 minutes |
| **Docker Image Size** | ~7.5-8.5 GB |
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

## F) References & Links

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

---

## License

MIT License - See [LICENSE](LICENSE) for details.

---

## Author

**Diego Nepomuceno Marcos**
- Email: me@diegonmarcos.com
- GitHub: [@diegonmarcos](https://github.com/diegonmarcos)
