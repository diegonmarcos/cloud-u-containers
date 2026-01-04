# Cloud Connect Container - Tools Reference

## Resource Usage Summary

| Category | Storage | RAM (idle) | RAM (active) |
|----------|---------|------------|--------------|
| Base System | ~800 MB | ~50 MB | ~100 MB |
| Shells | ~30 MB | ~5 MB | ~50 MB |
| CLI Tools | ~100 MB | ~0 MB | ~50 MB |
| Compilers | ~2.5 GB | ~0 MB | ~500 MB |
| Package Managers | ~1.5 GB | ~50 MB | ~200 MB |
| Privacy Tools | ~400 MB | ~30 MB | ~150 MB |
| Desktop/VNC | ~300 MB | ~100 MB | ~300 MB |
| GUI Apps | ~950 MB | ~0 MB | ~450 MB |
| **TOTAL** | **~6.5 GB** | **~235 MB** | **~1.8 GB** |

---

## Resource Usage by Tool

| Tool | Storage | RAM (idle) | RAM (active) | CPU Load |
|------|---------|------------|--------------|----------|
| **Base System** |||||
| base-devel | 300 MB | - | 50 MB | Low |
| git | 50 MB | - | 30 MB | Low |
| coreutils | 20 MB | - | 5 MB | Low |
| findutils | 5 MB | - | 5 MB | Low |
| openssh | 10 MB | 5 MB | 10 MB | Low |
| **Shells** |||||
| bash | 8 MB | 2 MB | 20 MB | Low |
| fish | 15 MB | 3 MB | 25 MB | Low |
| zsh | 7 MB | 2 MB | 20 MB | Low |
| **CLI Tools** |||||
| starship | 5 MB | 1 MB | 5 MB | Low |
| eza | 2 MB | - | 5 MB | Low |
| bat | 6 MB | - | 10 MB | Low |
| fd | 3 MB | - | 10 MB | Low |
| ripgrep | 5 MB | - | 20 MB | Medium |
| fzf | 3 MB | - | 15 MB | Low |
| zoxide | 2 MB | - | 5 MB | Low |
| htop | 1 MB | - | 10 MB | Low |
| jq | 1 MB | - | 5 MB | Low |
| **VPN & DNS** |||||
| protonvpn-cli | 150 MB | 10 MB | 50 MB | Low |
| cloudflared | 30 MB | 15 MB | 30 MB | Low |
| wireguard-tools | 5 MB | - | 10 MB | Low |
| openvpn | 10 MB | 5 MB | 20 MB | Low |
| **Compilers** |||||
| gcc | 500 MB | - | 200 MB | High |
| clang | 800 MB | - | 300 MB | High |
| cmake | 50 MB | - | 50 MB | Medium |
| ninja | 2 MB | - | 30 MB | Medium |
| make | 2 MB | - | 20 MB | Medium |
| rustup (cargo) | 600 MB | - | 150 MB | High |
| go | 500 MB | - | 100 MB | High |
| **Runtimes** |||||
| python | 100 MB | - | 50 MB | Medium |
| python-pip | 20 MB | - | 30 MB | Low |
| python-pipx | 10 MB | - | 20 MB | Low |
| nodejs | 80 MB | - | 100 MB | Medium |
| pnpm | 30 MB | - | 50 MB | Low |
| **Sandboxing** |||||
| uv | 20 MB | - | 30 MB | Low |
| nix | 1 GB | 30 MB | 150 MB | Medium |
| flatpak | 100 MB | 10 MB | 50 MB | Low |
| firejail | 5 MB | - | 20 MB | Low |
| **AI Tools** |||||
| claude-cli | 150 MB | - | 100 MB | Medium |
| gemini-cli | 50 MB | - | 80 MB | Medium |
| **Desktop** |||||
| tigervnc | 30 MB | 20 MB | 80 MB | Medium |
| openbox | 5 MB | 10 MB | 30 MB | Low |
| dmenu | 1 MB | - | 10 MB | Low |
| xorg-server | 100 MB | 50 MB | 150 MB | Medium |
| **GUI Apps** |||||
| falkon | 50 MB | - | 150 MB | Medium |
| dolphin | 50 MB | - | 100 MB | Low |
| konsole | 30 MB | - | 50 MB | Low |
| libreoffice-fresh | 800 MB | - | 300 MB | Medium |

---

## Tools by Category

### Base System
| Tool | Description |
|------|-------------|
| base-devel | Build tools (gcc, make, binutils, etc.) |
| git | Version control system |
| sudo | Privilege escalation |
| which | Locate commands |
| curl | URL transfer tool |
| wget | File downloader |
| coreutils | Basic file/text utilities (ls, cat, cp, etc.) |
| findutils | File search utilities (find, xargs) |
| grep | Pattern matching |
| sed | Stream editor |
| gawk | Text processing |
| less | Pager |
| tree | Directory tree view |
| htop | Process monitor |
| bc | Calculator |
| jq | JSON processor |

### Shells
| Tool | Description |
|------|-------------|
| bash | Bourne Again Shell (default) |
| fish | Friendly Interactive Shell |
| zsh | Z Shell (extensible) |
| starship | Cross-shell prompt |

### Network Tools
| Tool | Description |
|------|-------------|
| iproute2 | IP routing utilities |
| iputils | Network diagnostics (ping, etc.) |
| bind | DNS utilities (dig, nslookup) |
| net-tools | Legacy network tools (ifconfig, netstat) |
| openssh | SSH client/server |

### VPN & Privacy
| Tool | Description |
|------|-------------|
| protonvpn-cli | ProtonVPN command-line client |
| cloudflared | DNS-over-HTTPS (Cloudflare) |
| wireguard-tools | WireGuard VPN |
| openvpn | OpenVPN client |
| openresolv | DNS resolver manager |
| ca-certificates | SSL/TLS certificates |

### Modern CLI Tools
| Tool | Description |
|------|-------------|
| eza | Modern ls replacement |
| bat | Modern cat with syntax highlighting |
| fd | Modern find replacement |
| ripgrep | Modern grep replacement |
| fzf | Fuzzy finder |
| zoxide | Smarter cd command |

### Compilers & Build Tools
| Tool | Description |
|------|-------------|
| gcc | GNU C/C++ compiler |
| clang | LLVM C/C++ compiler |
| cmake | Cross-platform build system |
| ninja | Fast build system |
| make | GNU Make |
| rustup | Rust toolchain installer (includes cargo) |
| go | Go compiler and tools |

### Runtimes & Interpreters
| Tool | Description |
|------|-------------|
| python | Python 3 interpreter |
| python-pip | Python package installer |
| python-pipx | Install Python CLI tools isolated |
| nodejs | JavaScript runtime |
| pnpm | Fast Node.js package manager |

### Sandboxing & Package Managers
| Tool | Description |
|------|-------------|
| yay | AUR helper for Arch packages |
| uv | Fast Python package manager (replaces pip+poetry) |
| nix | Universal package manager with isolation |
| flatpak | Sandboxed desktop app manager |
| firejail | Application sandboxing |

### AI Tools
| Tool | Description |
|------|-------------|
| claude-cli | Anthropic Claude AI assistant |
| gemini-cli | Google Gemini AI assistant |

### Desktop Environment
| Tool | Description |
|------|-------------|
| tigervnc | VNC server |
| openbox | Lightweight window manager |
| dmenu | Dynamic menu/launcher |
| xorg-server | X11 display server |
| xorg-xinit | X11 initializer |
| xorg-fonts-misc | X11 misc fonts |
| xorg-fonts-type1 | X11 Type1 fonts |
| ttf-dejavu | DejaVu font family |
| breeze-icons | KDE icon theme |

### GUI Applications
| Tool | Description |
|------|-------------|
| falkon | Lightweight Qt-based browser |
| dolphin | KDE file manager |
| konsole | KDE terminal emulator |
| libreoffice-fresh | Office suite (Writer, Calc, Impress, Draw) |

---

## Notes

- **Storage**: Approximate installed size on disk
- **RAM (idle)**: Memory used when running but not active
- **RAM (active)**: Memory used during typical operation
- **CPU Load**: Low (<5%), Medium (5-30%), High (>30%)

### Minimum System Requirements
- **Storage**: 10 GB (6.5 GB tools + 3.5 GB buffer)
- **RAM**: 4 GB minimum, 8 GB recommended
- **CPU**: 2 cores minimum, 4 cores recommended
