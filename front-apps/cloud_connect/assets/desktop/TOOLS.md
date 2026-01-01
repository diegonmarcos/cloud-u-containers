# Cloud Connect - Pre-installed Tools Reference

> **Version**: 2.0
> **Base**: Arch Linux
> **Desktop**: Openbox (via VNC)

---

## Quick Start

```bash
# Start container
./cloud-connect.sh

# Container credentials
User:     clouduser
Sudo:     Passwordless
VNC Pass: cloudvnc (if VNC enabled)

# Enable VNC desktop
CLOUD_START_VNC=1 ./cloud-connect.sh
# Connect VNC client to localhost:5901

# Available shells
bash    # Default
fish    # Fish shell
zsh     # Zsh shell
```

---

## VNC Desktop Environment

### Openbox Window Manager

| Feature | Description | Usage |
|---------|-------------|-------|
| Right-click menu | Application launcher | Right-click desktop |
| Alt+F2 | dmenu run dialog | Alt+F2 |
| Alt+Tab | Window switch | Alt+Tab |
| Alt+F4 | Close window | Alt+F4 |
| Double-click titlebar | Maximize | Mouse |

### Desktop Apps (Qt-based)

| App | Description | Usage |
|-----|-------------|-------|
| Brave | Privacy browser | `brave` |
| Dolphin | File Manager | `dolphin` |
| Konsole | Terminal | `konsole` |
| dmenu | App launcher | Alt+F2 |

### File Management

| Tool | Description | Usage |
|------|-------------|-------|
| Dolphin | GUI File Manager | `dolphin` |
| eza | Modern ls | `ls`, `la`, `ll` |
| fd | Fast find | `fd pattern` |

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

### Core Commands

```bash
# Basic operations
g                   # git
gs                  # git status
ga                  # git add
gaa                 # git add --all
gc                  # git commit
gcm                 # git commit -m
gca                 # git commit --amend
gp                  # git push
gpf                 # git push --force-with-lease
gpl                 # git pull
gf                  # git fetch
gfa                 # git fetch --all --prune

# Branching
gco                 # git checkout
gcb                 # git checkout -b
gsw                 # git switch
gswc                # git switch -c
gb                  # git branch
gba                 # git branch -a
gbd                 # git branch -d
gbD                 # git branch -D

# Diff & Log
gd                  # git diff
gds                 # git diff --staged
gdw                 # git diff --word-diff
gl                  # git log --oneline -15
gla                 # git log --all --graph
glp                 # git log -p

# Stash
gst                 # git stash
gstp                # git stash pop
gstl                # git stash list
gsts                # git stash show -p
```

### TUI Tools

```bash
lg                  # lazygit (recommended)
gui                 # gitui (fast alternative)
tig                 # tig (text-mode interface)
tiga                # tig --all (all branches)
```

### Advanced Tools

```bash
# Git absorb - auto-fixup commits
gab                 # git absorb
gabr                # git absorb --and-rebase

# Git crypt - transparent encryption
gcrypt              # git-crypt
gcl                 # git-crypt lock
gcu                 # git-crypt unlock

# Utilities
gwip                # Quick WIP commit
gunwip              # Undo last commit (keep changes)
gundo               # Soft reset last commit
gamend              # Amend without editing message
gclean              # Clean untracked files
greset              # Hard reset to HEAD
grebase             # Interactive rebase
gcp                 # Cherry-pick
gref                # Reflog
```

### GitHub CLI

```bash
ghpr                # gh pr create
ghprl               # gh pr list
ghprv               # gh pr view
ghprc               # gh pr checkout
ghis                # gh issue list
ghic                # gh issue create
ghrepo              # gh repo view --web
```

### Tools Reference

| Tool | Command | Description |
|------|---------|-------------|
| **lazygit** | `lg` | Full-featured TUI git client |
| **gitui** | `gui` | Blazing fast TUI for git |
| **tig** | `tig` | Text-mode interface for git |
| **git-crypt** | `gcrypt` | Transparent file encryption in git |
| **git-absorb** | `gab` | Automatically absorb staged changes |
| **git-lfs** | `git lfs` | Large file storage |
| **delta** | (auto) | Syntax-highlighting pager for diffs |
| **difftastic** | `difft` | Structural diff tool |
| **gh** | `gh` | GitHub CLI |

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

## AI Assistants (Pre-installed)

### Claude CLI (Anthropic) - v2.x

```bash
claude              # Start Claude Code CLI
claude --version    # Check version (v2.0.76+)

# Usage
claude "explain this code"
claude -f file.py "review this"
claude              # Interactive mode

# Authentication
# Run `claude` and follow login prompts
```

### Gemini CLI (Google) - v0.22+

```bash
gemini              # Start Gemini CLI
gemini --version    # Check version

# Requires API key setup
export GEMINI_API_KEY="your-key"
gemini "your prompt"
```

### Both CLIs are globally accessible

```bash
which claude        # /usr/local/bin/claude
which gemini        # /usr/sbin/gemini
```

---

## Cloud Storage (rclone)

### Commands

```bash
rc                  # rclone
rcconfig            # rclone config (setup remotes)
rcls                # rclone ls (list files)
rclsd               # rclone lsd (list directories)
rccopy              # rclone copy
rcsync              # rclone sync
rcmount             # rclone mount
rccheck             # rclone check
rcsize              # rclone size
```

### Common Usage

```bash
# Configure a new remote
rclone config

# List remotes
rclone listremotes

# Sync local to cloud
rclone sync ~/Documents remote:backup/Documents

# Mount cloud storage
rclone mount remote:folder ~/mnt/cloud --daemon

# Copy with progress
rclone copy -P local/folder remote:folder
```

### Supported Providers

Google Drive, Dropbox, OneDrive, S3, Backblaze B2, Mega, pCloud,
Nextcloud, WebDAV, SFTP, and 40+ more.

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

Actual usage (tested):
- **Image size**: ~2.5 GB
- **Idle RAM**: ~200 MB (shell only)
- **With VNC**: ~500 MB
- **With Brave**: ~1.5 GB

This prevents the container from crashing the host system.

---

## Home Folder Structure

The container includes a pre-created home structure:

```
/home/clouduser/
├── apps/       # Local applications
├── git/        # Git repositories
├── mnt/        # Mount points
├── syncs/      # Sync folders
├── sys/        # System configs
├── user/       # User data
└── vault/      # Personal vault (empty)
```
