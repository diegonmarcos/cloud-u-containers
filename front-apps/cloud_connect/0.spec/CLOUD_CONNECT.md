# Cloud Connect

> **Product Spec & Architecture Design**
> **Version:** 0.1.0
> **Status:** Design
> **Type:** Rust CLI

---

## 1. Problem Statement

**Scenario:** User is on an untrusted/non-safe computer (public machine, borrowed laptop, fresh install) and needs to:

1. Work in an isolated environment that doesn't touch the host system
2. Establish secure network connectivity to personal cloud infrastructure
3. Access cloud-synced files with bidirectional sync
4. Use familiar tools with personal configurations

**Solution:** A single CLI that bootstraps a secure, isolated, fully-configured workstation environment.

---

## 2. Product Overview

```
cloud-connect [COMMAND]

COMMANDS:
    sandbox     Create/manage isolated Docker environment
    network     VPN + encrypted DNS + split tunnel setup
    sync        FUSE mounts + rclone bisync
    tools       Install and configure applications
    bootstrap   Run full setup (sandbox -> network -> sync -> tools)
    status      Overall system status
```

---

## 3. Architecture

### 3.1 High-Level Flow

```
+-----------------------------------------------------------------------+
|                        UNTRUSTED HOST                                  |
|  +-------------------------------------------------------------------+|
|  |                    DOCKER SANDBOX                                 ||
|  |                                                                   ||
|  |  +--------------+  +--------------+  +---------------------+      ||
|  |  |   Network    |  |    Sync      |  |       Tools         |      ||
|  |  |   Layer      |  |    Layer     |  |       Layer         |      ||
|  |  |              |  |              |  |                     |      ||
|  |  | WireGuard ---+--+-> FUSE -----+--+-> Brave             |      ||
|  |  | to Cloud     |  |   Mounts     |  |   Obsidian          |      ||
|  |  |              |  |              |  |   Konsole+Fish      |      ||
|  |  | Proton VPN --+--+-> rclone    |  |   Kate              |      ||
|  |  | Split Tunnel |  |   bisync     |  |   Dolphin           |      ||
|  |  |              |  |              |  |                     |      ||
|  |  | Encrypted    |  |              |  |   + Configs         |      ||
|  |  | DNS (DoH)    |  |              |  |   + Addons          |      ||
|  |  +--------------+  +--------------+  +---------------------+      ||
|  |                                                                   ||
|  +-------------------------------------------------------------------+|
|                                                                        |
+-----------------------------------------------------------------------+
```

### 3.2 Network Architecture (Split Tunnel)

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

### 3.3 Module Architecture

```
cloud_connect/
|-- Cargo.toml                  # Workspace definition
|
|-- crates/
|   |
|   |-- connect_lib/            # ================================
|   |   |-- Cargo.toml          # CORE LIBRARY
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
|   +-- connect_cli/            # ================================
|       |-- Cargo.toml          # CLI BINARY
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
|
|-- 0.spec/
|   +-- CLOUD_CONNECT.md        # This file
|
+-- 1.ops/
    +-- build.sh                # Build script
```

---

## 4. Module Specifications

### 4.1 Sandbox Module

**Purpose:** Create isolated Docker environment on untrusted hosts.

#### Commands

```bash
cloud-connect sandbox create [--name <name>]    # Create sandbox container
cloud-connect sandbox enter [--name <name>]     # Enter sandbox shell
cloud-connect sandbox stop [--name <name>]      # Stop sandbox
cloud-connect sandbox destroy [--name <name>]   # Remove sandbox + volumes
cloud-connect sandbox list                       # List sandboxes
cloud-connect sandbox status                     # Show sandbox status
```

#### Docker Image Spec

```dockerfile
FROM archlinux:latest

# Base system
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    base-devel git curl wget \
    wireguard-tools \
    fuse3 sshfs rclone \
    fish zsh starship \
    docker docker-compose

# GUI support (X11 forwarding)
RUN pacman -S --noconfirm \
    xorg-xhost xorg-xauth \
    gtk3 qt5-base

# Create user
ARG USER=sandbox
RUN useradd -m -G wheel,docker $USER
USER $USER
WORKDIR /home/$USER

# Entry point
ENTRYPOINT ["/bin/fish"]
```

#### Container Configuration

```rust
pub struct SandboxConfig {
    pub name: String,
    pub image: String,              // "cloud-connect-sandbox:latest"
    pub volumes: Vec<VolumeMount>,
    pub network_mode: String,       // "host" for VPN access
    pub privileged: bool,           // true for WireGuard
    pub capabilities: Vec<String>,  // NET_ADMIN, SYS_MODULE
    pub devices: Vec<String>,       // /dev/net/tun, /dev/fuse
    pub env: HashMap<String, String>,
    pub x11_forward: bool,
}
```

---

### 4.2 Network Module

**Purpose:** Establish secure, split-tunnel network connectivity.

#### Commands

```bash
# WireGuard (Cloud Infrastructure)
cloud-connect network wg up                  # Connect to cloud VPN
cloud-connect network wg down                # Disconnect
cloud-connect network wg status              # Show connection status

# Proton VPN (Public Internet)
cloud-connect network proton up              # Connect Proton VPN
cloud-connect network proton down            # Disconnect
cloud-connect network proton status          # Show status
cloud-connect network proton servers         # List free servers

# DNS
cloud-connect network dns set <provider>     # Set encrypted DNS
cloud-connect network dns status             # Show DNS config
cloud-connect network dns test               # Test DNS resolution

# Split Tunnel
cloud-connect network split enable           # Enable split tunnel mode
cloud-connect network split disable          # Disable (full tunnel)
cloud-connect network split status           # Show routing rules

# Full status
cloud-connect network status                 # All network status
```

#### Network Configuration

```rust
pub struct NetworkConfig {
    pub wireguard: WireGuardConfig,
    pub proton: ProtonConfig,
    pub dns: DnsConfig,
    pub split_tunnel: SplitTunnelConfig,
}

pub struct WireGuardConfig {
    pub interface: String,           // "wg0"
    pub config_path: PathBuf,        // Path to wg0.conf
    pub server_endpoint: String,     // "34.55.55.234:51820"
    pub allowed_ips: Vec<String>,    // ["10.0.0.0/24", "34.55.55.234/32"]
    pub persistent_keepalive: u16,   // 25
}

pub struct ProtonConfig {
    pub username: String,
    pub config_dir: PathBuf,         // OpenVPN configs
    pub protocol: String,            // "udp" | "tcp"
    pub server: Option<String>,      // Auto-select if None
}

pub struct DnsConfig {
    pub provider: DnsProvider,
    pub protocol: DnsProtocol,       // DoH | DoT | Plain
}

pub enum DnsProvider {
    Cloudflare,  // 1.1.1.1
    Quad9,       // 9.9.9.9
    Google,      // 8.8.8.8
    Custom(String),
}

pub struct SplitTunnelConfig {
    pub enabled: bool,
    pub wireguard_routes: Vec<String>,   // Routes via WireGuard
    pub proton_routes: Vec<String>,      // Routes via Proton (default)
    pub local_bypass: Vec<String>,       // Direct routes (LAN)
}
```

#### Split Tunnel Routing Logic

```
Traffic Type          -> Route Via
----------------------------------------------
10.0.0.0/24           -> WireGuard (cloud LAN)
34.55.55.234/32       -> WireGuard (GCP Hub)
84.235.234.87/32      -> WireGuard (OCI Flex)
130.110.251.193/32    -> WireGuard (OCI Mail)
129.151.228.66/32     -> WireGuard (OCI Analytics)
*.diegonmarcos.com    -> WireGuard (services)
192.168.0.0/16        -> Direct (local LAN)
0.0.0.0/0             -> Proton VPN (public internet)
```

---

### 4.3 Sync Module

**Purpose:** Mount cloud filesystems and configure bidirectional sync.

#### Commands

```bash
# FUSE Mounts
cloud-connect sync mount                     # Mount all configured remotes
cloud-connect sync mount <remote>            # Mount specific remote
cloud-connect sync unmount                   # Unmount all
cloud-connect sync mounts                    # List active mounts

# rclone Setup
cloud-connect sync rclone install            # Install rclone
cloud-connect sync rclone config             # Import rclone config
cloud-connect sync rclone remotes            # List configured remotes

# Bisync
cloud-connect sync bisync run                # Run bisync for all pairs
cloud-connect sync bisync run <pair>         # Run specific bisync pair
cloud-connect sync bisync status             # Show bisync status
cloud-connect sync bisync dry-run            # Preview sync changes
```

#### Sync Configuration

```rust
pub struct SyncConfig {
    pub mounts: Vec<MountConfig>,
    pub bisync_pairs: Vec<BisyncPair>,
    pub rclone_config_path: PathBuf,
}

pub struct MountConfig {
    pub name: String,                // "cloud-docs"
    pub remote: String,              // "gcp:" or "sftp-gcp:"
    pub remote_path: String,         // "/home/diego/Documents"
    pub local_path: PathBuf,         // "~/mnt/cloud/docs"
    pub mount_type: MountType,
    pub options: MountOptions,
}

pub enum MountType {
    Sshfs,                           // SSHFS mount
    RcloneMount,                     // rclone mount
}

pub struct BisyncPair {
    pub name: String,                // "obsidian-vault"
    pub path1: String,               // "~/Documents/Obsidian"
    pub path2: String,               // "gcp:/home/diego/Documents/Obsidian"
    pub filters: Option<PathBuf>,    // Filter rules file
    pub conflict_resolve: String,    // "newer" | "larger" | "path1" | "path2"
}
```

#### Default Mount Points

```
~/mnt/cloud/
|-- gcp/                    # GCP Hub home directory
|   |-- Documents/
|   |-- Projects/
|   +-- ...
|-- dev/                    # OCI Flex (wake-on-demand)
|   |-- data/
|   +-- ...
+-- sync/                   # Bisync staging area
    |-- obsidian/
    +-- configs/
```

---

### 4.4 Tools Module

**Purpose:** Install applications with configurations and addons.

#### Commands

```bash
# Install all tools
cloud-connect tools install                  # Install all configured tools
cloud-connect tools install <tool>           # Install specific tool

# Individual tools
cloud-connect tools brave install            # Install Brave
cloud-connect tools brave config             # Apply Brave config
cloud-connect tools brave addons             # Install extensions

cloud-connect tools obsidian install         # Install Obsidian
cloud-connect tools obsidian config          # Apply config + plugins

cloud-connect tools konsole install          # Install Konsole
cloud-connect tools konsole config           # Apply config + shell setup

cloud-connect tools kate install             # Install Kate
cloud-connect tools kate config              # Apply config + addons

cloud-connect tools dolphin install          # Install Dolphin
cloud-connect tools dolphin config           # Apply config

# Status
cloud-connect tools status                   # Show installed tools status
```

#### Tool Specifications

##### Brave Browser

```rust
pub struct BraveConfig {
    pub install_method: InstallMethod,   // Flatpak | Pacman | AUR
    pub profile_path: PathBuf,           // Import from cloud
    pub extensions: Vec<BraveExtension>,
}

pub struct BraveExtension {
    pub id: String,                      // Chrome Web Store ID
    pub name: String,
}
```

**Extensions to Install:**
| Extension | ID | Purpose |
|-----------|-----|---------|
| uBlock Origin | cjpalhdlnbpafiamejdnhcphjbkeiagm | Ad blocking |
| Bitwarden | nngceckbapebfimnlniiiahkandclblb | Passwords |
| Vimium | dbepggeogbaibhgnhhndojpepiihcmeb | Vim navigation |
| Dark Reader | eimadpbcbfnmbkopoojfekhnkhdbieeh | Dark mode |

##### Obsidian

```rust
pub struct ObsidianConfig {
    pub install_method: InstallMethod,   // Flatpak | AppImage
    pub vault_path: PathBuf,             // Synced vault location
    pub config_path: PathBuf,            // .obsidian/ config
    pub plugins: Vec<String>,
}
```

**Plugins to Install:**
| Plugin | Purpose |
|--------|---------|
| obsidian-git | Git sync |
| dataview | Query notes |
| templater | Templates |
| calendar | Calendar view |
| excalidraw | Diagrams |

##### Konsole + Shell

```rust
pub struct KonsoleConfig {
    pub profile: PathBuf,                // Konsole profile
    pub color_scheme: String,
    pub shell_config: ShellConfig,
}

pub struct ShellConfig {
    pub default_shell: Shell,            // Fish | Zsh
    pub fish_config: Option<PathBuf>,    // config.fish
    pub starship_config: PathBuf,        // starship.toml
    pub dotfiles: Vec<DotfileMapping>,
}

pub struct DotfileMapping {
    pub source: PathBuf,                 // In cloud/LOCAL_KEYS
    pub target: PathBuf,                 // In home directory
    pub method: DeployMethod,            // Symlink | Copy
}
```

**Dotfiles to Deploy:**
| File | Source | Target |
|------|--------|--------|
| config.fish | LOCAL_KEYS/configs/linux/fish/ | ~/.config/fish/ |
| starship.toml | LOCAL_KEYS/configs/linux/ | ~/.config/ |
| .gitconfig | LOCAL_KEYS/configs/git/ | ~/ |
| .aliases | LOCAL_KEYS/configs/linux/ | ~/ |

---

### 4.5 Bootstrap Module

**Purpose:** Orchestrate full setup sequence.

#### Command

```bash
cloud-connect bootstrap                      # Full setup with prompts
cloud-connect bootstrap --yes                # Non-interactive
cloud-connect bootstrap --skip <module>      # Skip specific module
cloud-connect bootstrap --only <module>      # Run only specific module
cloud-connect bootstrap status               # Show bootstrap progress
```

#### Bootstrap Sequence

```
+-----------------------------------------------------------+
|                  BOOTSTRAP SEQUENCE                        |
+-----------------------------------------------------------+
|                                                            |
|  1. PREFLIGHT CHECKS                                       |
|     +-- Docker installed?                                  |
|     +-- Network access?                                    |
|     +-- Config files accessible?                           |
|     +-- Required keys present?                             |
|                                                            |
|  2. SANDBOX SETUP                                          |
|     +-- Pull/build Docker image                            |
|     +-- Create container                                   |
|     +-- Configure volumes                                  |
|     +-- Setup X11 forwarding                               |
|                                                            |
|  3. NETWORK SETUP (inside sandbox)                         |
|     +-- Configure encrypted DNS                            |
|     +-- Setup WireGuard to cloud                           |
|     +-- Setup Proton VPN                                   |
|     +-- Configure split tunnel routing                     |
|     +-- Verify connectivity                                |
|                                                            |
|  4. SYNC SETUP                                             |
|     +-- Install rclone                                     |
|     +-- Import rclone config                               |
|     +-- Mount FUSE filesystems                             |
|     +-- Configure bisync pairs                             |
|     +-- Initial sync                                       |
|                                                            |
|  5. TOOLS SETUP                                            |
|     +-- Install Brave -> Apply config -> Add extensions    |
|     +-- Install Obsidian -> Apply config -> Add plugins    |
|     +-- Install Konsole -> Apply config -> Setup shell     |
|     +-- Install Kate -> Apply config -> Add plugins        |
|     +-- Install Dolphin -> Apply config                    |
|                                                            |
|  6. VERIFICATION                                           |
|     +-- All tools accessible?                              |
|     +-- Network routing correct?                           |
|     +-- Mounts working?                                    |
|     +-- Sync operational?                                  |
|                                                            |
+-----------------------------------------------------------+
```

---

## 5. Security Model

### 5.1 Threat Model

| Threat | Mitigation |
|--------|------------|
| Host keylogger | Docker isolation, no host shell access |
| Network sniffing | Encrypted DNS + VPN for all traffic |
| Local file access | Sandbox volumes limited to necessary paths |
| Credential theft | Keys stay in LOCAL_KEYS, accessed via mount |
| DNS leaks | DoH/DoT enforced, leak test on startup |
| Traffic analysis | Split tunnel hides cloud infrastructure |

### 5.2 Security Layers

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

---

## 6. Configuration File

### Location: `~/.config/cloud-connect/config.toml`

```toml
[general]
verbose = false
sandbox_name = "secure-workstation"

# ----------------------------------------
# SANDBOX
# ----------------------------------------
[sandbox]
image = "cloud-connect-sandbox:latest"
network_mode = "host"
privileged = true
x11_forward = true

[sandbox.volumes]
"/tmp/.X11-unix" = "/tmp/.X11-unix"
"~/.config/cloud-connect" = "/home/sandbox/.config/cloud-connect"

# ----------------------------------------
# NETWORK
# ----------------------------------------
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

# ----------------------------------------
# SYNC
# ----------------------------------------
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

# ----------------------------------------
# TOOLS
# ----------------------------------------
[tools.brave]
install_method = "flatpak"
profile_source = "LOCAL_KEYS/configs/browser/brave/"
extensions = [
    "cjpalhdlnbpafiamejdnhcphjbkeiagm",
    "nngceckbapebfimnlniiiahkandclblb",
    "dbepggeogbaibhgnhhndojpepiihcmeb",
    "eimadpbcbfnmbkopoojfekhnkhdbieeh",
]

[tools.obsidian]
install_method = "flatpak"
vault_path = "~/mnt/cloud/gcp/Documents/Obsidian"
config_source = "LOCAL_KEYS/configs/obsidian/"
plugins = [
    "obsidian-git",
    "dataview",
    "templater-obsidian",
    "calendar",
    "obsidian-excalidraw-plugin",
]

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

---

## 7. CLI Interface

### Global Options

```
cloud-connect [OPTIONS] <COMMAND>

OPTIONS:
    -v, --verbose       Verbose output
    -q, --quiet         Minimal output
    -c, --config <FILE> Config file path
    --json              JSON output (for scripting)
    --dry-run           Preview actions without executing
    -h, --help          Show help
    -V, --version       Show version
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

---

## 8. Implementation Phases

### Phase 1: Core Foundation
- [ ] Project structure
- [ ] CLI parser (clap)
- [ ] Config loader (TOML)
- [ ] Error handling

### Phase 2: Sandbox Module
- [ ] Docker image definition
- [ ] Container lifecycle (create/enter/stop/destroy)
- [ ] Volume management
- [ ] X11 forwarding setup

### Phase 3: Network Module
- [ ] WireGuard wrapper
- [ ] Proton VPN integration
- [ ] Encrypted DNS setup
- [ ] Split tunnel routing

### Phase 4: Sync Module
- [ ] rclone installation
- [ ] FUSE mount management
- [ ] Bisync configuration
- [ ] Mount status tracking

### Phase 5: Tools Module
- [ ] Package installation abstraction
- [ ] Brave setup + config import
- [ ] Obsidian setup + plugins
- [ ] Konsole + shell setup
- [ ] Kate + Dolphin setup

### Phase 6: Bootstrap Orchestration
- [ ] Preflight checks
- [ ] Sequential module execution
- [ ] Progress tracking
- [ ] Verification suite

---

## 9. Dependencies

### Cargo.toml

```toml
[package]
name = "cloud-connect"
version = "0.1.0"
edition = "2021"

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

## 10. Related Projects

- **Cloud Control**: The API/dashboard engine that manages the cloud infrastructure this tool connects to
  - Location: `back-System/cloud/a_solutions/front-apps/cloud_control/`
  - See: `CLOUD_CONTROL.md`
