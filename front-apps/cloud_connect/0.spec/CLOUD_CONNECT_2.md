# Cloud Connect

CLI tool for user/dev access to cloud infrastructure.

**Companion to:** `c3/` (Cloud Control Center)
**Shared backend with:** `cloud_control.py`

---

## Overview

```
cloud_connect.py
│
├── FRONT-END (User Interface)
│   ├── Helper (-h, --help, invalid arg)
│   ├── TUI (Interactive menu)
│   └── Direct CLI commands
│
└── BACK-END
    ├── VPN (WireGuard)
    ├── SSH connections
    ├── Mount (SSHFS)
    ├── Vault (Bitwarden CLI)
    └── Monitor/Status
```

---

## CLI Interface

### Entry Points

```bash
# Help/Helper
python cloud_connect.py -h
python cloud_connect.py --help
python cloud_connect.py <invalid>    # Shows helper

# TUI (no args)
python cloud_connect.py              # Interactive TUI

# Direct commands
python cloud_connect.py status       # Show full status + topology
python cloud_connect.py monitor      # Live monitor (auto-refresh)

# VPN
python cloud_connect.py vpn up       # Connect VPN
python cloud_connect.py vpn down     # Disconnect VPN
python cloud_connect.py vpn setup    # Setup WireGuard keys/config
python cloud_connect.py vpn split    # Split tunnel (only 10.0.0.x)
python cloud_connect.py vpn full     # Full tunnel (all traffic)

# SSH
python cloud_connect.py ssh <alias>  # SSH to VM (gcp, dev, web, services)
python cloud_connect.py ssh list     # List available hosts

# Mount
python cloud_connect.py mount        # Mount all (WG if up, else public)
python cloud_connect.py mount all    # Mount all
python cloud_connect.py mount <alias> # Mount specific VM
python cloud_connect.py unmount      # Unmount all
python cloud_connect.py unmount <alias>

# Vault
python cloud_connect.py vault        # Open vault manager
python cloud_connect.py vault status # Check vault status
python cloud_connect.py vault unlock # Unlock vault

# Setup
python cloud_connect.py setup        # Run all setup checks
python cloud_connect.py setup ssh    # SSH setup
python cloud_connect.py setup vpn    # VPN setup
python cloud_connect.py setup mount  # Mount driver setup

# Daemon
python cloud_connect.py daemon       # Auto-reconnect daemon
```

---

## Configuration

```python
@dataclass
class VM:
    name: str           # Display name: "GCP Hub"
    alias: str          # Short alias: "gcp"
    public_ip: str      # Public IP: "34.55.55.234"
    wg_ip: str          # WireGuard IP: "10.0.0.1"
    user: str           # SSH user: "diego"
    ssh_key: Path       # SSH key path
    ssh_method: str     # "gcloud" or "ssh"
    remote_path: str    # Mount path: "/home/diego"

VMS = [
    VM("GCP Hub",        "gcp",      "34.55.55.234",    "10.0.0.1", "diego",  SSH_KEY_GCP, "gcloud", "/home/diego"),
    VM("Oracle Dev",     "dev",      "84.235.234.87",   "10.0.0.2", "ubuntu", SSH_KEY_OCI, "ssh",    "/home/ubuntu"),
    VM("Oracle Web",     "web",      "130.110.251.193", "10.0.0.3", "ubuntu", SSH_KEY_OCI, "ssh",    "/home/ubuntu"),
    VM("Oracle Services","services", "129.151.228.66",  "10.0.0.4", "ubuntu", SSH_KEY_OCI, "ssh",    "/home/ubuntu"),
]
```

### Paths

```python
HOME = Path.home()
LOCAL_KEYS = HOME / "Documents/Git/LOCAL_KEYS"
SSH_KEY_GCP = LOCAL_KEYS / "00_terminal/ssh/google_compute_engine"
SSH_KEY_OCI = LOCAL_KEYS / "00_terminal/ssh/id_rsa"
WG_KEYS_DIR = LOCAL_KEYS / "00_terminal/wireguard"
MOUNT_BASE = HOME / "mnt/cloud"
WG_CONF = Path("/etc/wireguard/wg0.conf")
```

---

## Front-End

### Helper (-h | --help | invalid arg)

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         CLOUD CONNECT v2.0                                   ║
║                    VPN • SSH • Mount • Vault Manager                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

USAGE:
    cloud_connect.py [COMMAND] [OPTIONS]

COMMANDS:
    (none)              Open interactive TUI
    status              Show full status with topology
    monitor             Live monitor (auto-refresh)

  VPN:
    vpn up              Connect WireGuard VPN
    vpn down            Disconnect VPN
    vpn setup           Setup WireGuard keys & config
    vpn split           Split tunnel (only 10.0.0.x via VPN)
    vpn full            Full tunnel (all traffic via VPN)

  SSH:
    ssh <alias>         SSH to VM (gcp, dev, web, services)
    ssh list            List available SSH hosts

  MOUNT:
    mount [all|<alias>] Mount VMs via SSHFS
    unmount [all|<alias>] Unmount VMs

  VAULT:
    vault               Open vault manager
    vault status        Check Bitwarden status
    vault unlock        Unlock vault

  SETUP:
    setup [ssh|vpn|mount] Run setup/diagnostics

  DAEMON:
    daemon              Auto-reconnect daemon (background)

OPTIONS:
    -h, --help          Show this help
    -v, --verbose       Verbose output
    --public            Force public IPs (skip WireGuard)

EXAMPLES:
    cloud_connect.py                    # Interactive TUI
    cloud_connect.py status             # Full status
    cloud_connect.py ssh gcp            # SSH to GCP Hub
    cloud_connect.py vpn up && cloud_connect.py mount
    cloud_connect.py vpn full           # Route all traffic through VPN
```

---

### TUI (Interactive Menu)

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         CLOUD CONNECT v2.0                                   ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║                              ☁  INTERNET  ☁                                  ║
║                                     │                                        ║
║         ┌───────────────────────────┼───────────────────────────┐            ║
║         │                           │                           │            ║
║         ▼                           ▼                           ▼            ║
║   ┌───────────┐              ┌───────────┐              ┌───────────┐        ║
║   │Oracle Dev │              │  GCP Hub  │              │Oracle Web │        ║
║   │84.235.234 │              │34.55.55   │              │130.110.251│        ║
║   └─────┬─────┘              └─────┬─────┘              └─────┬─────┘        ║
║         │                          │                          │              ║
║         └──────────────────────────┼──────────────────────────┘              ║
║                    WireGuard VPN (10.0.0.0/24)                               ║
║                         ◉ CONNECTED (split)                                  ║
║                                    │                                         ║
║                              ┌─────┴─────┐                                   ║
║                              │  10.0.0.5 │                                   ║
║                              │   LOCAL   │                                   ║
║                              └───────────┘                                   ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  VM STATUS                                                                   ║
║  ──────────────────────────────────────────────────────────────────────────  ║
║  VM              WG IP        Public IP        WG      Public    Mount       ║
║  GCP Hub         10.0.0.1     34.55.55.234     12ms    45ms      ●           ║
║  Oracle Dev      10.0.0.2     84.235.234.87    18ms    52ms      ●           ║
║  Oracle Web      10.0.0.3     130.110.251.193  15ms    48ms      ○           ║
║  Oracle Services 10.0.0.4     129.151.228.66   20ms    55ms      ●           ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  VPN: ◉ UP (split) │ Transfer: ↓ 1.2MB ↑ 456KB │ Mounts: 3/4 │ Vault: 🔓    ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          ║
║  │ [V] VPN     │  │ [S] SSH     │  │ [M] Mount   │  │ [B] Vault   │          ║
║  │             │  │             │  │             │  │             │          ║
║  │  v) up      │  │  1) gcp     │  │  m) all     │  │  b) open    │          ║
║  │  d) down    │  │  2) dev     │  │  u) unmount │  │  l) lock    │          ║
║  │  t) toggle  │  │  3) web     │  │  a) pub IP  │  │  s) sync    │          ║
║  │  f) full    │  │  4) services│  │             │  │             │          ║
║  │  p) split   │  │             │  │  1-4) indiv │  │             │          ║
║  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘          ║
║                                                                              ║
║  [X] Setup        [R] Refresh       [?] Help        [Q] Quit                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

 >
```

---

## Menu Structure

### 0. Monitor / Status

**Features:**
- Network topology diagram (ASCII art)
- VM status table with ping latencies
- VPN status (up/down, split/full, handshake, transfer)
- Mount status
- Vault status
- Public IP detection

**Topology Diagram:**
```
                              ☁  INTERNET  ☁
                                     │
         ┌───────────────────────────┼───────────────────────────┐
         │                           │                           │
         ▼                           ▼                           ▼
   ┌───────────┐              ┌───────────┐              ┌───────────┐
   │Oracle Dev │              │  GCP Hub  │              │Oracle Web │
   │84.235.234 │              │34.55.55   │              │130.110.251│
   └─────┬─────┘              └─────┬─────┘              └─────┬─────┘
         │                          │                          │
         └──────────────────────────┼──────────────────────────┘
                    WireGuard VPN (10.0.0.0/24)
                         ◉ CONNECTED
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
              ┌─────────┐    ┌───────────┐    ┌─────────────┐
              │10.0.0.4 │    │  10.0.0.5 │    │Oracle Svcs  │
              │OCI Svcs │    │   LOCAL   │    │129.151.228  │
              └─────────┘    └───────────┘    └─────────────┘
```

---

### 1. VPN (WireGuard)

| Action | Key | Command | Description |
|--------|-----|---------|-------------|
| Connect | `v` | `wg-quick up wg0` | Bring up VPN |
| Disconnect | `d` / `V` | `wg-quick down wg0` | Bring down VPN |
| Toggle tunnel | `t` | - | Switch split↔full |
| Full tunnel | `f` | - | All traffic via VPN |
| Split tunnel | `p` | - | Only 10.0.0.x via VPN |
| Setup | `s` | - | Generate keys, install config |

**Tunnel Modes:**

| Mode | AllowedIPs | Use Case |
|------|------------|----------|
| Split | `10.0.0.0/24` | Access VMs only, normal internet |
| Full | `0.0.0.0/0, ::/0` | All traffic through VPN (privacy) |

**VPN Status Checks:**
- `wg show wg0` - Interface status
- `wg show wg0 latest-handshakes` - Connection health
- `wg show wg0 transfer` - Bandwidth stats

---

### 2. SSH

| Action | Key | Command |
|--------|-----|---------|
| SSH to GCP | `1` | `gcloud compute ssh arch-1 --zone=us-central1-a` |
| SSH to Dev | `2` | `ssh -i <key> ubuntu@84.235.234.87` |
| SSH to Web | `3` | `ssh -i <key> ubuntu@130.110.251.193` |
| SSH to Services | `4` | `ssh -i <key> ubuntu@129.151.228.66` |

**SSH Method by Provider:**

| Provider | Method | Command |
|----------|--------|---------|
| GCP | gcloud | `gcloud compute ssh <vm> --zone=<zone>` |
| OCI | ssh -i | `ssh -i <key> <user>@<ip>` |

**IP Selection:**
- If VPN up → use WG IP (10.0.0.x)
- If VPN down → use Public IP

---

### 3. Mount (SSHFS)

| Action | Key | Description |
|--------|-----|-------------|
| Mount all | `m` | Mount all VMs (WG if up, else public) |
| Unmount all | `u` / `M` | Unmount all |
| Mount (public) | `a` | Force public IPs |
| Toggle individual | `1-4` | Mount/unmount specific VM |

**Mount Logic:**

```python
def mount_vm(vm, use_wg=True):
    # Try WireGuard IP first
    if use_wg:
        try_mount(vm.wg_ip)

    # Fallback to public IP
    try_mount(vm.public_ip)
```

**SSHFS Options:**
```bash
sshfs -o IdentityFile=<key> \
      -o StrictHostKeyChecking=no \
      -o reconnect \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o ConnectTimeout=8 \
      user@ip:/path /local/mount
```

**Stale Mount Cleanup:**
```python
def clean_stale_mount(mp):
    subprocess.run(["fusermount", "-uz", str(mp)])  # Lazy unmount
```

---

### 4. Vault (Bitwarden CLI)

| Action | Key | Description |
|--------|-----|-------------|
| Open vault | `b` | Interactive vault menu |
| Lock | `l` | Lock vault |
| Sync | `s` | Sync with server |
| Status | - | Check bw status |

**Vault Status Checks:**

| State | Command | Action |
|-------|---------|--------|
| Not installed | `which bw` | Prompt install |
| Not logged in | `bw status` → unauthenticated | Run `bw login` |
| Locked | `bw status` → locked | Run `bw unlock` |
| Unlocked | `bw status` → unlocked | Show menu |

**Vault Menu:**
```
┌─────────────────────────────────────────────────────────┐
│  VAULT (Bitwarden)                                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Status: 🔓 Unlocked                                    │
│  User: me@diegonmarcos.com                              │
│  Last sync: 2 hours ago                                 │
│                                                         │
│  [1] Search credentials                                 │
│  [2] Get SSH key passphrase                            │
│  [3] Get API token                                      │
│  [4] Sync vault                                         │
│  [5] Lock vault                                         │
│                                                         │
│  [B] Back                                               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

### 5. Setup

**Setup Menu:**
```
┌─────────────────────────────────────────────────────────┐
│  SETUP & DIAGNOSTICS                                    │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  SSH SETUP                                              │
│  ✓ ~/.ssh exists                                        │
│  ✓ id_rsa symlinked from LOCAL_KEYS                    │
│  ✓ google_compute_engine present                        │
│  ✓ ssh-agent running                                    │
│  ✗ Key not added to agent                              │
│                                                         │
│  VPN SETUP                                              │
│  ✓ WireGuard tools installed                           │
│  ✓ Keys generated                                       │
│  ✓ Config installed (/etc/wireguard/wg0.conf)          │
│  ✓ Can reach GCP Hub                                    │
│                                                         │
│  MOUNT SETUP                                            │
│  ✓ FUSE installed                                       │
│  ✓ SSHFS installed                                      │
│  ✓ User in fuse group                                   │
│  ✓ Mount base exists (~/mnt/cloud)                     │
│                                                         │
│  VAULT SETUP                                            │
│  ✓ Bitwarden CLI installed                             │
│  ✓ Logged in                                            │
│  ✗ Vault locked                                         │
│                                                         │
│  [1] Fix SSH (add key to agent)                        │
│  [2] Fix VPN (run setup)                               │
│  [3] Fix Mount (create dirs)                           │
│  [4] Fix Vault (unlock)                                │
│  [A] Fix All                                            │
│                                                         │
│  [B] Back                                               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Setup Checks:**

| Category | Check | Command |
|----------|-------|---------|
| SSH | Dir exists | `ls ~/.ssh` |
| SSH | Key symlinked | `readlink ~/.ssh/id_rsa` |
| SSH | Agent running | `ssh-add -l` |
| SSH | Key loaded | `ssh-add -l \| grep id_rsa` |
| VPN | Tools installed | `which wg` |
| VPN | Keys exist | `ls LOCAL_KEYS/wireguard/` |
| VPN | Config exists | `test -f /etc/wireguard/wg0.conf` |
| Mount | FUSE installed | `which fusermount` |
| Mount | SSHFS installed | `which sshfs` |
| Mount | User in group | `groups \| grep fuse` |
| Vault | CLI installed | `which bw` |
| Vault | Logged in | `bw status` |

---

### 6. Daemon Mode

Auto-reconnect daemon for persistent connections:

```python
def daemon():
    while running:
        # Check VPN
        if not vpn_is_up():
            vpn_up()

        # Check mounts
        if vpn_is_up():
            for vm in VMS:
                if not is_mounted(vm):
                    mount_vm(vm, use_wg=True)

        sleep(30)
```

**Usage:**
```bash
# Foreground
python cloud_connect.py daemon

# Background (systemd or nohup)
nohup python cloud_connect.py daemon &
```

---

## TUI Keybindings

### Main Screen

| Key | Action |
|-----|--------|
| `v` | VPN up |
| `d` / `V` | VPN down |
| `t` | Toggle tunnel (split↔full) |
| `f` | Full tunnel |
| `p` | Split tunnel |
| `s` | VPN setup |
| `1-4` | SSH to VM |
| `m` | Mount all |
| `u` / `M` | Unmount all |
| `a` | Mount (public IPs) |
| `Shift+1-4` | Toggle individual mount |
| `b` | Vault menu |
| `x` / `X` | Setup menu |
| `r` / `R` | Refresh |
| `?` | Help |
| `q` / `Q` | Quit |

---

## Status Bar

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  VPN: ◉ UP (split) │ Transfer: ↓ 1.2MB ↑ 456KB │ Mounts: 3/4 │ Vault: 🔓    ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

| Indicator | States |
|-----------|--------|
| VPN | `◉ UP (split)` / `◉ UP (full)` / `○ DOWN` |
| Transfer | `↓ RX ↑ TX` |
| Mounts | `3/4` (mounted/total) |
| Vault | `🔓` (unlocked) / `🔒` (locked) / `✗` (not installed) |

---

## Folder Structure

```
cloud_connect/
├── CLOUD_CONNECT.md          # This spec
├── cloud_connect.py          # Main CLI + TUI (monolith)
└── requirements.txt          # No external deps (stdlib only)
```

**Optional modular structure (future):**
```
cloud_connect/
├── CLOUD_CONNECT.md
├── cloud_connect.py          # Entry point + TUI
├── lib/
│   ├── __init__.py
│   ├── vpn.py                # VPN functions
│   ├── ssh.py                # SSH functions
│   ├── mount.py              # Mount functions
│   ├── vault.py              # Vault functions
│   ├── status.py             # Status/monitor
│   └── config.py             # VM dataclass + constants
└── requirements.txt
```

---

## Dependencies

**None** - stdlib only:
- `subprocess`
- `sys`, `os`, `time`, `signal`
- `pathlib.Path`
- `dataclasses.dataclass`
- `concurrent.futures.ThreadPoolExecutor`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        cloud_connect.py                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │   CLI    │  │   TUI    │  │  Helper  │  │  Daemon  │        │
│  │  Parser  │  │  Loop    │  │  Screen  │  │   Mode   │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │             │             │             │               │
│       └─────────────┴─────────────┴─────────────┘               │
│                           │                                      │
│  ┌────────────────────────┴────────────────────────┐            │
│  │                   FUNCTIONS                      │            │
│  ├──────────┬──────────┬──────────┬───────────────┤            │
│  │   VPN    │   SSH    │  Mount   │    Vault      │            │
│  │ wg-quick │ gcloud   │  sshfs   │    bw         │            │
│  │ wg show  │ ssh -i   │fusermount│  status       │            │
│  └──────────┴──────────┴──────────┴───────────────┘            │
│                           │                                      │
│  ┌────────────────────────┴────────────────────────┐            │
│  │                   CONFIG                         │            │
│  │  VMS[] dataclass  │  LOCAL_KEYS paths           │            │
│  └─────────────────────────────────────────────────┘            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Pipeline

```
User Input
    │
    ▼
┌─────────┐     ┌─────────┐     ┌─────────┐
│   CLI   │ or  │   TUI   │ or  │  Daemon │
└────┬────┘     └────┬────┘     └────┬────┘
     │               │               │
     └───────────────┴───────────────┘
                     │
                     ▼
              ┌─────────────┐
              │  Functions  │
              │ vpn/ssh/mnt │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │  subprocess │
              │   (shell)   │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │   System    │
              │ wg/ssh/sshfs│
              └─────────────┘
```
