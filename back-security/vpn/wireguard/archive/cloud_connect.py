#!/usr/bin/env python3
"""
Cloud Connect - VPN & Mount Manager
"""

import subprocess
import sys
import os
import time
import signal
from pathlib import Path
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor, as_completed

# ============================================================================
# CONFIGURATION
# ============================================================================

@dataclass
class VM:
    name: str
    alias: str
    public_ip: str
    wg_ip: str
    user: str
    ssh_key: Path
    remote_path: str


HOME = Path.home()
LOCAL_KEYS = HOME / "Documents/Git/LOCAL_KEYS"
SSH_KEY_GCP = LOCAL_KEYS / "00_terminal/ssh/google_compute_engine"
SSH_KEY_OCI = LOCAL_KEYS / "00_terminal/ssh/id_rsa"
WG_KEYS_DIR = LOCAL_KEYS / "00_terminal/wireguard"
MOUNT_BASE = HOME / "mnt/cloud"
WG_CONF = Path("/etc/wireguard/wg0.conf")
WG_INTERFACE = "wg0"

GCP_HUB_PUBKEY = "GGZzgZDrOwvw1Th8iKWKeOOBgh+UvAjnmdi1iE9E1Hk="
ORACLE_WEB_PUBKEY = "1E7ofexq/gHZXnLNXFvpm9O6qtZDJD40IfSpHZ7Pezc="
ORACLE_WEB_ENDPOINT = "130.110.251.193:51820"
LOCAL_WG_IP = "10.0.0.5"

# Tunnel modes
# Split: Connect to GCP mesh (access VMs only)
# Full: Connect directly to Oracle Web (all internet traffic)
SPLIT_TUNNEL = "10.0.0.0/24"
FULL_TUNNEL = "0.0.0.0/0, ::/0"

VMS = [
    VM("GCP Hub", "gcp", "34.55.55.234", "10.0.0.1", "diego", SSH_KEY_GCP, "/home/diego"),
    VM("Oracle Dev", "dev", "84.235.234.87", "10.0.0.2", "ubuntu", SSH_KEY_OCI, "/home/ubuntu"),
    VM("Oracle Web", "web", "130.110.251.193", "10.0.0.3", "ubuntu", SSH_KEY_OCI, "/home/ubuntu"),
    VM("Oracle Services", "services", "129.151.228.66", "10.0.0.4", "ubuntu", SSH_KEY_OCI, "/home/ubuntu"),
]

# Colors
class C:
    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    MAGENTA = "\033[95m"
    CYAN = "\033[96m"
    WHITE = "\033[97m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RESET = "\033[0m"


# ============================================================================
# UTILITIES
# ============================================================================

def run(cmd: list[str], sudo: bool = False, timeout: int = 10) -> tuple[int, str, str]:
    """Run command and return (code, stdout, stderr)."""
    if sudo:
        cmd = ["sudo"] + cmd
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    except Exception as e:
        return 1, "", str(e)


def ping(ip: str, count: int = 1, timeout: int = 2) -> tuple[bool, float]:
    """Ping IP and return (success, latency_ms)."""
    code, out, _ = run(["ping", "-c", str(count), "-W", str(timeout), ip], timeout=timeout+2)
    if code == 0:
        try:
            for line in out.split("\n"):
                if "avg" in line:
                    latency = float(line.split("/")[4])
                    return True, latency
            return True, 0.0
        except:
            return True, 0.0
    return False, 0.0


def clear_screen():
    print("\033[2J\033[H", end="")


def get_public_ip() -> str:
    """Get local machine's public IP."""
    code, out, _ = run(["curl", "-s", "--max-time", "3", "ifconfig.me"], timeout=5)
    return out if code == 0 else "unknown"


# ============================================================================
# VPN FUNCTIONS
# ============================================================================

def vpn_is_up() -> bool:
    code, _, _ = run(["ip", "link", "show", WG_INTERFACE])
    return code == 0


def vpn_has_handshake() -> bool:
    code, out, _ = run(["wg", "show", WG_INTERFACE, "latest-handshakes"], sudo=True)
    if code != 0:
        return False
    for line in out.split("\n"):
        if GCP_HUB_PUBKEY in line:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    handshake_time = int(parts[1])
                    return (time.time() - handshake_time) < 180
                except:
                    pass
    return False


def vpn_get_transfer() -> tuple[str, str]:
    """Get VPN transfer stats."""
    code, out, _ = run(["wg", "show", WG_INTERFACE, "transfer"], sudo=True)
    if code != 0:
        return "0 B", "0 B"
    for line in out.split("\n"):
        if GCP_HUB_PUBKEY in line:
            parts = line.split()
            if len(parts) >= 3:
                rx = int(parts[1])
                tx = int(parts[2])
                def fmt(b):
                    for u in ['B', 'KB', 'MB', 'GB']:
                        if b < 1024:
                            return f"{b:.1f}{u}"
                        b /= 1024
                    return f"{b:.1f}TB"
                return fmt(rx), fmt(tx)
    return "0 B", "0 B"


def wg_tools_installed() -> bool:
    code, _, _ = run(["which", "wg"])
    return code == 0


def wg_keys_exist() -> tuple[bool, str]:
    priv = WG_KEYS_DIR / "privatekey"
    pub = WG_KEYS_DIR / "publickey"
    if priv.exists() and pub.exists():
        return True, pub.read_text().strip()
    return False, ""


def wg_config_exists() -> bool:
    code, _, _ = run(["test", "-f", str(WG_CONF)], sudo=True)
    return code == 0


def vpn_up() -> bool:
    if vpn_is_up():
        print(f"  {C.YELLOW}VPN already up{C.RESET}")
        return True
    if not wg_config_exists():
        print(f"  {C.RED}Config not found: {WG_CONF}{C.RESET}")
        return False
    code, _, err = run(["wg-quick", "up", WG_INTERFACE], sudo=True, timeout=15)
    if code == 0:
        print(f"  {C.GREEN}VPN connected{C.RESET}")
        return True
    print(f"  {C.RED}VPN failed: {err}{C.RESET}")
    return False


def vpn_down() -> bool:
    if not vpn_is_up():
        print(f"  {C.YELLOW}VPN already down{C.RESET}")
        return True
    code, _, err = run(["wg-quick", "down", WG_INTERFACE], sudo=True, timeout=10)
    if code == 0:
        print(f"  {C.GREEN}VPN disconnected{C.RESET}")
        return True
    print(f"  {C.RED}Failed: {err}{C.RESET}")
    return False


def get_tunnel_mode() -> str:
    """Get current tunnel mode from config. Returns 'split', 'full', or 'unknown'."""
    code, out, _ = run(["cat", str(WG_CONF)], sudo=True)
    if code != 0:
        return "unknown"
    if "0.0.0.0/0" in out:
        return "full"
    elif "10.0.0.0/24" in out:
        return "split"
    return "unknown"


def set_tunnel_mode(mode: str) -> bool:
    """Set tunnel mode ('split' or 'full'). Restarts VPN if running."""
    if mode not in ("split", "full"):
        print(f"  {C.RED}Invalid mode: {mode}{C.RESET}")
        return False

    was_up = vpn_is_up()
    if was_up:
        print(f"  Stopping VPN...")
        run(["wg-quick", "down", WG_INTERFACE], sudo=True, timeout=10)

    # Read private key
    priv_key_file = WG_KEYS_DIR / "privatekey"
    if not priv_key_file.exists():
        print(f"  {C.RED}Private key not found. Run 'vpn setup' first.{C.RESET}")
        return False
    priv_key = priv_key_file.read_text().strip()

    if mode == "full":
        # Full tunnel: Direct to Oracle Web (better bandwidth)
        config = f"""[Interface]
PrivateKey = {priv_key}
Address = {LOCAL_WG_IP}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
# Oracle Web - Internet Exit
PublicKey = {ORACLE_WEB_PUBKEY}
AllowedIPs = {FULL_TUNNEL}
Endpoint = {ORACLE_WEB_ENDPOINT}
PersistentKeepalive = 25
"""
        mode_name = f"FULL via Oracle ({ORACLE_WEB_ENDPOINT.split(':')[0]})"
    else:
        # Split tunnel: GCP mesh (access all VMs)
        config = f"""[Interface]
PrivateKey = {priv_key}
Address = {LOCAL_WG_IP}/24

[Peer]
# GCP Hub - Mesh Access
PublicKey = {GCP_HUB_PUBKEY}
AllowedIPs = {SPLIT_TUNNEL}
Endpoint = {VMS[0].public_ip}:51820
PersistentKeepalive = 25
"""
        mode_name = "SPLIT via GCP (VPN only)"

    tmp_conf = Path("/tmp/wg0.conf")
    tmp_conf.write_text(config)
    run(["mkdir", "-p", "/etc/wireguard"], sudo=True)
    code, _, err = run(["cp", str(tmp_conf), str(WG_CONF)], sudo=True)
    if code != 0:
        print(f"  {C.RED}Failed to write config: {err}{C.RESET}")
        return False
    run(["chmod", "600", str(WG_CONF)], sudo=True)
    tmp_conf.unlink()

    print(f"  {C.GREEN}Tunnel mode set to: {mode_name}{C.RESET}")

    if was_up:
        print(f"  Restarting VPN...")
        code, _, err = run(["wg-quick", "up", WG_INTERFACE], sudo=True, timeout=10)
        if code != 0:
            print(f"  {C.RED}Failed to restart: {err}{C.RESET}")
            return False
        print(f"  {C.GREEN}VPN restarted{C.RESET}")

    return True


def vpn_setup() -> bool:
    print(f"\n{C.BOLD}=== VPN Setup ==={C.RESET}\n")
    if not wg_tools_installed():
        print(f"  {C.RED}WireGuard not installed{C.RESET}")
        print(f"  Install: sudo pacman -S wireguard-tools")
        return False

    WG_KEYS_DIR.mkdir(parents=True, exist_ok=True)
    priv_key_file = WG_KEYS_DIR / "privatekey"
    pub_key_file = WG_KEYS_DIR / "publickey"

    if priv_key_file.exists() and pub_key_file.exists():
        priv_key = priv_key_file.read_text().strip()
        pub_key = pub_key_file.read_text().strip()
        print(f"  Keys exist: {pub_key[:32]}...")
    else:
        print(f"  Generating new keys...")
        code, priv_key, _ = run(["wg", "genkey"])
        if code != 0:
            return False
        proc = subprocess.run(["wg", "pubkey"], input=priv_key, capture_output=True, text=True)
        pub_key = proc.stdout.strip()
        priv_key_file.write_text(priv_key)
        pub_key_file.write_text(pub_key)
        os.chmod(priv_key_file, 0o600)
        print(f"  Keys saved: {pub_key[:32]}...")

    config = f"""[Interface]
PrivateKey = {priv_key}
Address = {LOCAL_WG_IP}/24

[Peer]
# GCP Hub
PublicKey = {GCP_HUB_PUBKEY}
AllowedIPs = 10.0.0.0/24
Endpoint = {VMS[0].public_ip}:51820
PersistentKeepalive = 25
"""
    tmp_conf = Path("/tmp/wg0.conf")
    tmp_conf.write_text(config)
    run(["mkdir", "-p", "/etc/wireguard"], sudo=True)
    code, _, err = run(["cp", str(tmp_conf), str(WG_CONF)], sudo=True)
    if code == 0:
        run(["chmod", "600", str(WG_CONF)], sudo=True)
        tmp_conf.unlink()
        print(f"  {C.GREEN}Config installed{C.RESET}")
        return True
    print(f"  {C.RED}Failed: {err}{C.RESET}")
    return False


# ============================================================================
# MOUNT FUNCTIONS
# ============================================================================

def mount_point(vm: VM) -> Path:
    return MOUNT_BASE / vm.alias


def is_mounted(vm: VM) -> bool:
    mp = mount_point(vm)
    code, _, _ = run(["mountpoint", "-q", str(mp)])
    return code == 0


def clean_stale_mount(mp: Path) -> None:
    """Clean up stale/broken SSHFS mount."""
    # Try unmount first (handles stale mounts)
    subprocess.run(["fusermount", "-uz", str(mp)], capture_output=True, timeout=5)
    time.sleep(0.3)
    # Verify cleanup worked
    try:
        if mp.exists():
            list(mp.iterdir())
    except OSError:
        # Still broken, try harder
        subprocess.run(["fusermount", "-uz", str(mp)], capture_output=True, timeout=5)
        time.sleep(0.5)
        # Last resort: lazy unmount
        subprocess.run(["umount", "-l", str(mp)], capture_output=True, timeout=5)


def mount_vm(vm: VM, use_wg: bool = True, verbose: bool = False) -> tuple[bool, str]:
    """Mount a VM via SSHFS. Returns (success, error_msg)."""
    mp = mount_point(vm)
    if is_mounted(vm):
        return True, ""
    clean_stale_mount(mp)
    mp.mkdir(parents=True, exist_ok=True)

    # Try WireGuard IP first, then fall back to public IP
    ips_to_try = []
    if use_wg:
        ips_to_try.append(("WG", vm.wg_ip))
    ips_to_try.append(("Public", vm.public_ip))

    last_err = ""
    for ip_type, ip in ips_to_try:
        # Clean before each attempt (failed sshfs leaves broken mounts)
        clean_stale_mount(mp)
        mp.mkdir(parents=True, exist_ok=True)

        cmd = [
            "sshfs",
            "-o", f"IdentityFile={vm.ssh_key}",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "reconnect",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=8",
            f"{vm.user}@{ip}:{vm.remote_path}",
            str(mp)
        ]
        if verbose:
            print(f"    Trying {ip_type} ({ip})...", end=" ", flush=True)
        code, _, err = run(cmd, timeout=15)
        if code == 0:
            if verbose:
                print(f"{C.GREEN}OK{C.RESET}")
            return True, ""
        last_err = err or f"{ip_type} connection failed"
        if verbose:
            print(f"{C.RED}FAIL{C.RESET}")

    return False, last_err


def unmount_vm(vm: VM) -> bool:
    mp = mount_point(vm)
    if not is_mounted(vm):
        return True
    code, _, _ = run(["fusermount", "-u", str(mp)])
    if code != 0:
        code, _, _ = run(["fusermount", "-uz", str(mp)])
    return code == 0


def mount_all(use_wg: bool = True, verbose: bool = True) -> None:
    print(f"\n{C.BOLD}Mounting all VMs...{C.RESET}")
    for vm in VMS:
        print(f"  {vm.name}:", end=" ", flush=True)
        ok, err = mount_vm(vm, use_wg, verbose=False)
        if ok:
            print(f"{C.GREEN}OK{C.RESET}")
        else:
            print(f"{C.RED}FAIL{C.RESET} - {err}" if err else f"{C.RED}FAIL{C.RESET}")


def unmount_all() -> None:
    print(f"\n{C.BOLD}Unmounting all VMs...{C.RESET}")
    for vm in VMS:
        ok = unmount_vm(vm)
        s = f"{C.GREEN}OK{C.RESET}" if ok else f"{C.RED}FAIL{C.RESET}"
        print(f"  {vm.name}: {s}")


# ============================================================================
# STATUS
# ============================================================================

def get_full_status() -> dict:
    """Get comprehensive status."""
    status = {
        "wg_tools": wg_tools_installed(),
        "wg_keys": wg_keys_exist(),
        "wg_config": wg_config_exists(),
        "vpn_up": vpn_is_up(),
        "vpn_handshake": False,
        "vpn_transfer": ("0 B", "0 B"),
        "tunnel_mode": get_tunnel_mode(),
        "public_ip": "",
        "vms": {}
    }

    if status["vpn_up"]:
        status["vpn_handshake"] = vpn_has_handshake()
        status["vpn_transfer"] = vpn_get_transfer()

    # Parallel checks
    def check_vm(vm):
        wg_ok, wg_lat = ping(vm.wg_ip) if status["vpn_up"] else (False, 0)
        pub_ok, pub_lat = ping(vm.public_ip)
        mounted = is_mounted(vm)
        return vm.alias, {
            "name": vm.name,
            "wg_ip": vm.wg_ip,
            "public_ip": vm.public_ip,
            "wg_ping": wg_ok,
            "wg_latency": wg_lat,
            "pub_ping": pub_ok,
            "pub_latency": pub_lat,
            "mounted": mounted,
            "mount_path": str(mount_point(vm)),
        }

    with ThreadPoolExecutor(max_workers=5) as ex:
        futures = [ex.submit(check_vm, vm) for vm in VMS]
        futures.append(ex.submit(get_public_ip))
        for f in as_completed(futures):
            r = f.result()
            if isinstance(r, tuple):
                alias, data = r
                status["vms"][alias] = data
            else:
                status["public_ip"] = r

    return status


def print_topology(status: dict) -> None:
    """Print network topology diagram."""
    vpn_up = status["vpn_up"]
    vms = status["vms"]

    vpn_color = C.GREEN if vpn_up else C.RED
    vpn_status = "CONNECTED" if vpn_up else "DISCONNECTED"

    print(f"""
{C.BOLD}╔══════════════════════════════════════════════════════════════════════════════╗
║                        WIREGUARD MESH NETWORK                                  ║
╚══════════════════════════════════════════════════════════════════════════════╝{C.RESET}

                              {C.CYAN}☁  INTERNET  ☁{C.RESET}
                                     │
         ┌───────────────────────────┼───────────────────────────┐
         │                           │                           │
         ▼                           ▼                           ▼
   ┌───────────┐              ┌───────────┐              ┌───────────┐
   │{C.MAGENTA}Oracle Dev{C.RESET} │              │ {C.CYAN}GCP Hub{C.RESET}  │              │{C.MAGENTA}Oracle Web{C.RESET}│
   │{vms.get('dev',{}).get('public_ip','--'):^11}│              │{vms.get('gcp',{}).get('public_ip','--'):^11}│              │{vms.get('web',{}).get('public_ip','--'):^11}│
   └─────┬─────┘              └─────┬─────┘              └─────┬─────┘
         │                           │                           │
         │    ╔═══════════════════════════════════════════╗      │
         └────║      WireGuard VPN (10.0.0.0/24)          ║──────┘
              ║           {vpn_color}{vpn_status:^20}{C.RESET}            ║
              ╚═══════════════╤═══════════════════════════╝
                              │
   ┌──────────────────────────┼──────────────────────────┐
   │                          │                          │
   ▼                          ▼                          ▼
┌─────────┐            ┌─────────────┐            ┌─────────────┐
│{C.YELLOW}10.0.0.2{C.RESET} │            │  {C.GREEN}10.0.0.1{C.RESET}   │            │  {C.YELLOW}10.0.0.3{C.RESET}   │
│ OCI Dev │◄──────────►│   GCP Hub   │◄──────────►│   OCI Web   │
└─────────┘            └──────┬──────┘            └─────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
        ┌─────────┐    ┌───────────┐    ┌─────────────┐
        │{C.YELLOW}10.0.0.4{C.RESET} │    │  {C.GREEN}10.0.0.5{C.RESET}  │    │{C.MAGENTA}Oracle Svcs{C.RESET} │
        │OCI Svcs │    │   LOCAL   │    │{vms.get('services',{}).get('public_ip','--'):^13}│
        └─────────┘    └───────────┘    └─────────────┘
""")


def print_status_table(status: dict) -> None:
    """Print detailed status table."""
    keys_ok, pub_key = status["wg_keys"]
    rx, tx = status["vpn_transfer"]

    # VPN Status Section
    print(f"\n{C.BOLD}╔══════════════════════════════════════════════════════════════════════════════╗")
    print(f"║                              VPN STATUS                                       ║")
    print(f"╚══════════════════════════════════════════════════════════════════════════════╝{C.RESET}")

    tools_s = f"{C.GREEN}Installed{C.RESET}" if status["wg_tools"] else f"{C.RED}Not installed{C.RESET}"
    keys_s = f"{C.GREEN}Found{C.RESET}" if keys_ok else f"{C.RED}Not found{C.RESET}"
    conf_s = f"{C.GREEN}Found{C.RESET}" if status["wg_config"] else f"{C.RED}Not found{C.RESET}"
    vpn_s = f"{C.GREEN}UP{C.RESET}" if status["vpn_up"] else f"{C.RED}DOWN{C.RESET}"
    hs_s = f"{C.GREEN}Active{C.RESET}" if status["vpn_handshake"] else f"{C.DIM}None{C.RESET}"

    # Tunnel mode display
    tmode = status.get("tunnel_mode", "unknown")
    if tmode == "full":
        tmode_s = f"{C.YELLOW}FULL{C.RESET} (all traffic via VPN)"
    elif tmode == "split":
        tmode_s = f"{C.GREEN}SPLIT{C.RESET} (only 10.0.0.x via VPN)"
    else:
        tmode_s = f"{C.DIM}unknown{C.RESET}"

    print(f"""
  WireGuard Tools: {tools_s}
  Local Keys:      {keys_s}
  Public Key:      {C.CYAN}{pub_key[:44] if pub_key else 'N/A'}{C.RESET}
  Config File:     {conf_s}
  Interface:       {vpn_s}
  Tunnel Mode:     {tmode_s}
  Handshake:       {hs_s}
  Transfer:        ↓ {C.GREEN}{rx}{C.RESET}  ↑ {C.YELLOW}{tx}{C.RESET}
  Your Public IP:  {C.CYAN}{status['public_ip']}{C.RESET}
  Your WG IP:      {C.GREEN}{LOCAL_WG_IP}{C.RESET}
""")

    # VM Status Section
    print(f"{C.BOLD}╔══════════════════════════════════════════════════════════════════════════════╗")
    print(f"║                              VM STATUS                                        ║")
    print(f"╚══════════════════════════════════════════════════════════════════════════════╝{C.RESET}")

    print(f"\n  {'VM':<16} {'WG IP':<12} {'Public IP':<16} {'WG Ping':<10} {'Pub Ping':<10} {'Mount'}")
    print(f"  {'-'*76}")

    for vm in VMS:
        d = status["vms"].get(vm.alias, {})

        wg_p = f"{C.GREEN}{d.get('wg_latency',0):.0f}ms{C.RESET}" if d.get('wg_ping') else f"{C.RED}--{C.RESET}"
        pub_p = f"{C.GREEN}{d.get('pub_latency',0):.0f}ms{C.RESET}" if d.get('pub_ping') else f"{C.RED}--{C.RESET}"
        mnt = f"{C.GREEN}YES{C.RESET}" if d.get('mounted') else f"{C.DIM}no{C.RESET}"

        print(f"  {vm.name:<16} {vm.wg_ip:<12} {vm.public_ip:<16} {wg_p:<18} {pub_p:<18} {mnt}")

    # Local machine status
    print(f"  {'-'*76}")
    local_wg = f"{C.GREEN}OK{C.RESET}" if status["vpn_up"] else f"{C.RED}--{C.RESET}"
    local_pub = f"{C.CYAN}{status['public_ip'][:15]}{C.RESET}" if status['public_ip'] else "--"
    print(f"  {C.CYAN}{'Local (this)':<16}{C.RESET} {LOCAL_WG_IP:<12} {local_pub:<24} {local_wg:<18} {C.DIM}--{C.RESET}")

    # Mount Points
    print(f"\n{C.BOLD}╔══════════════════════════════════════════════════════════════════════════════╗")
    print(f"║                            MOUNT POINTS                                       ║")
    print(f"╚══════════════════════════════════════════════════════════════════════════════╝{C.RESET}")

    print(f"\n  Base: {C.CYAN}{MOUNT_BASE}{C.RESET}\n")
    for vm in VMS:
        d = status["vms"].get(vm.alias, {})
        mp = mount_point(vm)
        if d.get('mounted'):
            print(f"  {C.GREEN}●{C.RESET} {mp}")
        else:
            print(f"  {C.DIM}○ {mp}{C.RESET}")
    print()


def print_help_status() -> None:
    """Print help with live status."""
    status = get_full_status()

    print(f"""
{C.BOLD}{C.CYAN}╔══════════════════════════════════════════════════════════════════════════════╗
║                         CLOUD CONNECT v1.0                                    ║
║                      VPN & Mount Manager                                      ║
╚══════════════════════════════════════════════════════════════════════════════╝{C.RESET}

{C.BOLD}USAGE:{C.RESET}
    cloud_connect.py              Open interactive TUI
    cloud_connect.py status       Show detailed status
    cloud_connect.py vpn up       Connect VPN
    cloud_connect.py vpn down     Disconnect VPN
    cloud_connect.py vpn setup    Setup VPN keys & config
    cloud_connect.py vpn split    Split tunnel (only 10.0.0.x via VPN)
    cloud_connect.py vpn full     Full tunnel (ALL traffic via VPN)
    cloud_connect.py mount        Mount all VMs
    cloud_connect.py unmount      Unmount all VMs
    cloud_connect.py daemon       Run as auto-reconnect daemon

{C.BOLD}TUI KEYS:{C.RESET}
    v  VPN up          V  VPN down        s  Setup VPN
    t  Toggle tunnel   f  Full tunnel     p  Split tunnel
    m  Mount all       M  Unmount all     a  Mount (public IP)
    1-4  Toggle individual mount
    r  Refresh         q  Quit
""")

    print_topology(status)
    print_status_table(status)


# ============================================================================
# TUI
# ============================================================================

def tui() -> None:
    """Interactive TUI."""
    running = True

    def handle_signal(sig, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, handle_signal)

    while running:
        clear_screen()
        status = get_full_status()

        print_topology(status)
        print_status_table(status)

        # Show current tunnel mode
        tmode = status.get("tunnel_mode", "unknown")
        tmode_hint = "→full" if tmode == "split" else "→split"

        print(f"{C.BOLD}  ACTIONS:{C.RESET}")
        print(f"  {C.CYAN}v{C.RESET}) VPN up     {C.CYAN}V{C.RESET}) VPN down     {C.CYAN}s{C.RESET}) Setup VPN")
        print(f"  {C.CYAN}t{C.RESET}) Toggle tunnel ({tmode_hint})   {C.CYAN}f{C.RESET}) Full tunnel   {C.CYAN}p{C.RESET}) Split tunnel")
        print(f"  {C.CYAN}m{C.RESET}) Mount all  {C.CYAN}M{C.RESET}) Unmount all  {C.CYAN}a{C.RESET}) Mount (public IP)")
        print(f"  {C.CYAN}1{C.RESET}) GCP  {C.CYAN}2{C.RESET}) Dev  {C.CYAN}3{C.RESET}) Web  {C.CYAN}4{C.RESET}) Services  (toggle mount)")
        print(f"  {C.CYAN}r{C.RESET}) Refresh    {C.CYAN}q{C.RESET}) Quit")
        print()

        try:
            choice = input(f"  {C.BOLD}>{C.RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            break

        if choice == 'q':
            break
        elif choice == 'v':
            vpn_up()
            time.sleep(2)
        elif choice == 'V':
            vpn_down()
            time.sleep(1)
        elif choice == 's':
            vpn_setup()
            input("\n  Press Enter...")
        elif choice == 't':
            # Toggle tunnel mode
            new_mode = "full" if status.get("tunnel_mode") == "split" else "split"
            set_tunnel_mode(new_mode)
            time.sleep(2)
        elif choice == 'f':
            set_tunnel_mode("full")
            time.sleep(2)
        elif choice == 'p':
            set_tunnel_mode("split")
            time.sleep(2)
        elif choice == 'm':
            mount_all(use_wg=status["vpn_up"])
            time.sleep(1)
        elif choice == 'M':
            unmount_all()
            time.sleep(1)
        elif choice == 'a':
            mount_all(use_wg=False)
            time.sleep(1)
        elif choice == 'r':
            continue
        elif choice in ['1', '2', '3', '4']:
            vm = VMS[int(choice) - 1]
            if is_mounted(vm):
                unmount_vm(vm)
                print(f"  {vm.name}: Unmounted")
            else:
                ok, err = mount_vm(vm, use_wg=status["vpn_up"])
                if ok:
                    print(f"  {vm.name}: {C.GREEN}Mounted{C.RESET}")
                else:
                    print(f"  {vm.name}: {C.RED}Failed{C.RESET} - {err}" if err else f"  {vm.name}: {C.RED}Failed{C.RESET}")
            time.sleep(1)

    print(f"\n{C.DIM}Goodbye!{C.RESET}\n")


# ============================================================================
# DAEMON
# ============================================================================

def daemon() -> None:
    """Auto-reconnect daemon."""
    print(f"{C.BOLD}Cloud Connect Daemon{C.RESET}")
    print(f"Press Ctrl+C to stop\n")

    running = True

    def handle_signal(sig, frame):
        nonlocal running
        running = False
        print(f"\n{C.YELLOW}Shutting down...{C.RESET}")

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    while running:
        try:
            if not vpn_is_up():
                print(f"{time.strftime('%H:%M:%S')} {C.YELLOW}VPN down, reconnecting...{C.RESET}")
                vpn_up()
                time.sleep(2)

            if vpn_is_up():
                for vm in VMS:
                    if not is_mounted(vm):
                        ok, _ = mount_vm(vm, use_wg=True)
                        if ok:
                            print(f"{time.strftime('%H:%M:%S')} {C.GREEN}Mounted {vm.name}{C.RESET}")

            for _ in range(30):
                if not running:
                    break
                time.sleep(1)

        except Exception as e:
            print(f"{C.RED}Error: {e}{C.RESET}")
            time.sleep(5)

    print(f"{C.GREEN}Daemon stopped{C.RESET}")


# ============================================================================
# MAIN
# ============================================================================

def main() -> None:
    MOUNT_BASE.mkdir(parents=True, exist_ok=True)

    if len(sys.argv) < 2:
        tui()
        return

    cmd = sys.argv[1].lower()

    if cmd in ["-h", "--help", "help"]:
        print_help_status()

    elif cmd == "status":
        status = get_full_status()
        print_topology(status)
        print_status_table(status)

    elif cmd == "vpn":
        if len(sys.argv) < 3:
            print("Usage: cloud_connect.py vpn [up|down|setup|split|full]")
            return
        sub = sys.argv[2].lower()
        if sub == "up":
            vpn_up()
        elif sub == "down":
            vpn_down()
        elif sub == "setup":
            vpn_setup()
        elif sub == "split":
            set_tunnel_mode("split")
        elif sub == "full":
            set_tunnel_mode("full")
        else:
            print(f"Unknown vpn command: {sub}")
            print("Usage: cloud_connect.py vpn [up|down|setup|split|full]")

    elif cmd == "mount":
        mount_all(use_wg=vpn_is_up())

    elif cmd == "unmount":
        unmount_all()

    elif cmd == "daemon":
        daemon()

    else:
        print(f"Unknown: {cmd}")
        print("Use --help for usage")
        sys.exit(1)


if __name__ == "__main__":
    main()
