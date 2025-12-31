# Cloud Desktop - Pre-installed Tools Reference

> **Version**: 2.0
> **Base**: Arch Linux
> **Desktop**: KDE Plasma

---

## Quick Start

```bash
# First login credentials
User:     diegonmarcos
Password: changeme (MUST change on first login)

# Default shell
Shell: Fish (with Zsh also available)

# Switch shells
fish    # Switch to Fish
zsh     # Switch to Zsh
```

---

## Desktop Environment

### KDE Plasma

| App | Description | Shortcut |
|-----|-------------|----------|
| Dolphin | File Manager | `files` or `dolphin` |
| Konsole | Terminal | `term` or `konsole` |
| Kate | Text Editor | `k` or `kate` |
| Yakuake | Drop-down Terminal | F12 |
| Spectacle | Screenshots | Print Screen |
| Gwenview | Image Viewer | - |
| Okular | PDF Viewer | - |

### File Management

| Tool | Description | Usage |
|------|-------------|-------|
| Yazi | TUI File Manager | `y` or `yazi` |
| Dolphin | GUI File Manager | `files` |
| eza | Modern ls | `ls`, `la`, `ll`, `lt` |

---

## Development Tools

### Languages & Runtimes

| Language | Version | Package Manager |
|----------|---------|-----------------|
| **Python** | 3.x | pip, pipx, poetry |
| **Node.js** | LTS | npm, pnpm, yarn |
| **Rust** | Stable | cargo (rustup) |
| **Go** | Latest | go mod |
| **Lua** | 5.x | luarocks |

### Python Tools

```bash
# Installed packages
python-pip          # Package manager
python-pipx         # Isolated app installer
python-virtualenv   # Virtual environments
python-poetry       # Dependency management
python-numpy        # Numerical computing
python-pandas       # Data analysis
python-matplotlib   # Plotting
python-requests     # HTTP library
python-pytest       # Testing
python-black        # Code formatter
python-pylint       # Linter
python-mypy         # Type checker
ipython             # Enhanced REPL
jupyter-notebook    # Interactive notebooks

# Aliases
py                  # python
pip                 # pip3
venv                # python -m venv
activate            # source .venv/bin/activate
ipy                 # ipython
jn                  # jupyter notebook
```

### Node.js Tools

```bash
# Package managers
npm                 # Default
pnpm                # Fast, efficient
yarn                # Classic

# Global packages
typescript          # TypeScript compiler
eslint              # Linter
prettier            # Formatter
biome               # Fast linter/formatter

# Aliases
ni                  # npm install
nid                 # npm install -D
nr                  # npm run
nrd                 # npm run dev
nrb                 # npm run build
pni                 # pnpm install
pnr                 # pnpm run
```

### Rust Tools

```bash
# Toolchain (via rustup)
rustc               # Compiler
cargo               # Package manager
rust-analyzer       # LSP server
clippy              # Linter
rustfmt             # Formatter

# Cargo extensions
cargo-edit          # Add/rm deps from CLI
cargo-watch         # File watcher
cargo-expand        # Macro expansion
cargo-outdated      # Check outdated deps

# CLI tools (cargo install)
tokei               # Code statistics
hyperfine           # Benchmarking
du-dust             # Disk usage (dust)
procs               # Process viewer
bottom              # System monitor (btm)

# Aliases
c                   # cargo
cb                  # cargo build
cr                  # cargo run
ct                  # cargo test
cc                  # cargo check
ccl                 # cargo clippy
cf                  # cargo fmt
cw                  # cargo watch -x run
```

---

## Editors

| Editor | Command | Description |
|--------|---------|-------------|
| Neovim | `v`, `vim`, `nvim` | Default editor |
| VS Code | `code` | GUI IDE |
| Kate | `k`, `kate` | KDE editor |

---

## Terminal & Shell

### Fish Shell (Default)

```bash
# Features
- Autosuggestions (Ctrl+F to accept)
- Syntax highlighting
- Smart completions

# Configuration
~/.config/fish/config.fish
```

### Zsh Shell

```bash
# Switch to Zsh
zsh

# Features
- Autosuggestions
- Syntax highlighting
- Shared aliases with Fish

# Configuration
~/.zshrc
```

### Starship Prompt

Both shells use Starship prompt for consistent experience.

```bash
# Configuration
~/.config/starship.toml
```

---

## CLI Utilities

### Modern Replacements

| Classic | Modern | Alias |
|---------|--------|-------|
| ls | eza | `ls`, `la`, `ll`, `lt` |
| cat | bat | `cat` |
| grep | ripgrep | `grep`, `rg` |
| find | fd | `find`, `ff`, `fdir` |
| top | btop | `top`, `htop` |
| ps | procs | `ps` |
| du | dust | `du` |
| diff | delta | Git integration |

### Fuzzy Finding

```bash
fzf                 # Fuzzy finder
Ctrl+T              # Find files
Ctrl+R              # Search history
Alt+C               # cd to directory
```

### Smart Navigation

```bash
zoxide              # Smart cd
z <partial>         # Jump to directory
zi                  # Interactive selection
```

---

## Git & Version Control

### Commands

```bash
# Aliases
g                   # git
gs                  # git status
ga                  # git add
gaa                 # git add --all
gc                  # git commit
gcm                 # git commit -m
gp                  # git push
gpl                 # git pull
gf                  # git fetch
gco                 # git checkout
gcb                 # git checkout -b
gb                  # git branch
gd                  # git diff
gds                 # git diff --staged
gl                  # git log (short)
gla                 # git log --all
gst                 # git stash
gstp                # git stash pop
lg                  # lazygit (TUI)
```

### Tools

| Tool | Description |
|------|-------------|
| lazygit | TUI git client |
| gh | GitHub CLI |
| delta | Diff highlighter |
| difftastic | Structural diff |

---

## Docker & Containers

```bash
# Aliases
d                   # docker
dc                  # docker compose
dps                 # docker ps
dpsa                # docker ps -a
di                  # docker images
dex                 # docker exec -it
dlog                # docker logs -f
drm                 # docker rm
drmi                # docker rmi
dprune              # docker system prune -af

# Also available
podman              # Docker alternative
buildah             # Container builder
```

---

## Networking & VPN

### VPN Tools

```bash
# ProtonVPN
vpnc                # protonvpn-cli connect
vpnd                # protonvpn-cli disconnect
vpns                # protonvpn-cli status

# WireGuard
wgup                # sudo wg-quick up wg0
wgdown              # sudo wg-quick down wg0
wgs                 # sudo wg show

# OpenVPN
openvpn             # OpenVPN client
```

### Network Utilities

```bash
ports               # ss -tulpn (show ports)
myip                # Show public IP
ping                # ping -c 5
ip                  # ip -c (colored)
```

---

## Package Management

### Pacman (Official)

```bash
pac                 # sudo pacman
pacs                # sudo pacman -S
pacr                # sudo pacman -Rns
pacu                # sudo pacman -Syu
pacq                # pacman -Q
pacqs               # pacman -Qs
pacf                # pacman -F
```

### Yay (AUR)

```bash
ya                  # yay
yas                 # yay -S
yau                 # yay -Syu
```

---

## Applications

### Browsers & Apps

| App | Command | Description |
|-----|---------|-------------|
| Brave | `browser`, `brave` | Privacy browser |
| Obsidian | `notes`, `obsidian` | Note-taking |
| VS Code | `code` | IDE |
| Spotify | `music`, `spotify` | Music |
| Proton Mail | `mail`, `proton-mail` | Email |
| Bitwarden | `bitwarden` | Password manager |

### Bitwarden CLI

```bash
# Aliases
bwl                 # bw login
bwu                 # bw unlock
bwsync              # bw sync
bwls                # bw list items
bwget <name>        # bw get item <name>
bwpass <name>       # bw get password <name>
bwuser <name>       # bw get username <name>
bwsearch <query>    # bw list items --search <query>

# Common workflows
bw login                          # Login to vault
export BW_SESSION=$(bw unlock --raw)  # Unlock and set session
bw sync                           # Sync with server
bw get password github.com        # Get password for site
bw get item "SSH Key"             # Get item by name
```

---

## System Monitoring

```bash
btop                # System monitor (top/htop)
procs               # Process list (ps)
dust                # Disk usage (du)
bottom              # Alternative monitor (btm)
free -h             # Memory usage
df -h               # Disk space
```

---

## File Operations

```bash
# Safe operations (with confirmation)
cp                  # cp -iv
mv                  # mv -iv
rm                  # rm -iv
mkdir               # mkdir -pv

# Quick commands
md <dir>            # mkdir -pv
mkcd <dir>          # mkdir && cd
backup <file>       # Create timestamped backup
extract <archive>   # Extract any archive
```

---

## Keyboard Shortcuts

### Terminal

| Shortcut | Action |
|----------|--------|
| Ctrl+F | Accept autosuggestion |
| Ctrl+R | Search history |
| Ctrl+T | Find files (fzf) |
| Alt+C | cd to directory (fzf) |
| Ctrl+Z | Undo |
| Tab | Autocomplete |

### KDE Plasma

| Shortcut | Action |
|----------|--------|
| F12 | Yakuake terminal |
| Meta | Application menu |
| Meta+E | File manager |
| Alt+F2 | Run command |
| Print | Screenshot |

---

## Configuration Files

```
~/.config/
├── fish/
│   └── config.fish     # Fish configuration
├── starship.toml       # Prompt configuration
├── yazi/
│   └── yazi.toml       # Yazi configuration
└── nvim/               # Neovim configuration

~/.zshrc                # Zsh configuration
/etc/profile.d/cloud-aliases.sh  # Shared aliases
```

---

## Updating

```bash
# Update system
pacu                # sudo pacman -Syu
yau                 # yay -Syu (includes AUR)

# Update Rust
rustup update

# Update npm global packages
npm update -g

# Update cargo tools
cargo install-update -a  # If cargo-update is installed
```

---

## Tips

1. **Use Fish** - It has better defaults and autosuggestions
2. **Use Yazi** - Faster than Dolphin for quick navigation (`y`)
3. **Use fzf** - Ctrl+R for history, Ctrl+T for files
4. **Use zoxide** - Just type `z partial-path` to jump
5. **Use lazygit** - Much easier than git commands (`lg`)
6. **Use btop** - Beautiful system monitor

---

## Resource Limits

This container is configured to never exceed:
- **CPU**: 90% of host CPUs
- **Memory**: 90% of host RAM
- **Swap**: Equal to memory limit

This prevents the desktop from crashing the host system.
