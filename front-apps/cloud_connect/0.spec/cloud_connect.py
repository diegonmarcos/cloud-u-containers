#!/usr/bin/env python3
"""
Cloud Connect v2.0 - VPN, SSH, Mount & Vault Manager
"""

import subprocess
import sys
import os
import time
import signal
import json
from pathlib import Path
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

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
    ssh_method: str  # "gcloud" or "ssh"
    remote_path: str
    gcp_zone: str = ""  # Only for GCP VMs


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

SPLIT_TUNNEL = "10.0.0.0/24"
FULL_TUNNEL = "0.0.0.0/0, ::/0"

VMS = [
    VM("GCP Hub",         "gcp",      "34.55.55.234",    "10.0.0.1", "diego",  SSH_KEY_GCP, "gcloud", "/home/diego", "us-central1-a"),
    VM("Oracle Dev",      "dev",      "84.235.234.87",   "10.0.0.2", "ubuntu", SSH_KEY_OCI, "ssh",    "/home/ubuntu"),
    VM("Oracle Web",      "web",      "130.110.251.193", "10.0.0.3", "ubuntu", SSH_KEY_OCI, "ssh",    "/home/ubuntu"),
    VM("Oracle Services", "services", "129.151.228.66",  "10.0.0.4", "ubuntu", SSH_KEY_OCI, "ssh",    "/home/ubuntu"),
]

VERSION = "2.0"

# ============================================================================
# COLORS & UI
# ============================================================================

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
    # Box drawing
    TL = "╔"
    TR = "╗"
    BL = "╚"
    BR = "╝"
    H = "═"
    V = "║"
    LT = "╠"
    RT = "╣"


def box_top(width: int = 80) -> str:
    return f"{C.TL}{C.H * (width - 2)}{C.TR}"


def box_mid(width: int = 80) -> str:
    return f"{C.LT}{C.H * (width - 2)}{C.RT}"


def box_bot(width: int = 80) -> str:
    return f"{C.BL}{C.H * (width - 2)}{C.BR}"


def box_line(text: str, width: int = 80) -> str:
    stripped = strip_ansi(text)
    padding = width - 4 - len(stripped)
    return f"{C.V}  {text}{' ' * max(0, padding)}{C.V}"


def strip_ansi(text: str) -> str:
    import re
    return re.sub(r'\033\[[0-9;]*m', '', text)


def clear_screen():
    print("\033[2J\033[H", end="")


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


def run_interactive(cmd: list[str], sudo: bool = False) -> int:
    """Run command interactively (for SSH)."""
    if sudo:
        cmd = ["sudo"] + cmd
    try:
        return subprocess.call(cmd)
    except Exception as e:
        print(f"{C.RED}Error: {e}{C.RESET}")
        return 1


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


def get_public_ip() -> str:
    """Get local machine's public IP."""
    code, out, _ = run(["curl", "-s", "--max-time", "3", "ifconfig.me"], timeout=5)
    return out if code == 0 else "unknown"


def find_vm(alias: str) -> Optional[VM]:
    """Find VM by alias."""
    for vm in VMS:
        if vm.alias == alias or vm.name.lower() == alias.lower():
            return vm
    return None


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
    """Get current tunnel mode from config."""
    code, out, _ = run(["cat", str(WG_CONF)], sudo=True)
    if code != 0:
        return "unknown"
    if "0.0.0.0/0" in out:
        return "full"
    elif "10.0.0.0/24" in out:
        return "split"
    return "unknown"


def set_tunnel_mode(mode: str) -> bool:
    """Set tunnel mode ('split' or 'full')."""
    if mode not in ("split", "full"):
        print(f"  {C.RED}Invalid mode: {mode}{C.RESET}")
        return False

    was_up = vpn_is_up()
    if was_up:
        print(f"  Stopping VPN...")
        run(["wg-quick", "down", WG_INTERFACE], sudo=True, timeout=10)

    priv_key_file = WG_KEYS_DIR / "privatekey"
    if not priv_key_file.exists():
        print(f"  {C.RED}Private key not found. Run 'vpn setup' first.{C.RESET}")
        return False
    priv_key = priv_key_file.read_text().strip()

    if mode == "full":
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

    print(f"  {C.GREEN}Tunnel mode: {mode_name}{C.RESET}")

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
# SSH FUNCTIONS
# ============================================================================

def ssh_to_vm(vm: VM, use_wg: bool = True) -> int:
    """SSH to a VM. Returns exit code."""
    # Determine IP to use
    if use_wg and vpn_is_up():
        ip = vm.wg_ip
        ip_type = "WG"
    else:
        ip = vm.public_ip
        ip_type = "Public"

    print(f"\n  {C.CYAN}Connecting to {vm.name} ({ip_type}: {ip})...{C.RESET}\n")

    if vm.ssh_method == "gcloud":
        cmd = ["gcloud", "compute", "ssh", "arch-1", f"--zone={vm.gcp_zone}"]
    else:
        cmd = [
            "ssh",
            "-i", str(vm.ssh_key),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            f"{vm.user}@{ip}"
        ]

    return run_interactive(cmd)


def ssh_list() -> None:
    """List available SSH hosts."""
    print(f"\n{C.BOLD}Available SSH Hosts:{C.RESET}\n")
    vpn_up = vpn_is_up()
    for i, vm in enumerate(VMS, 1):
        ip = vm.wg_ip if vpn_up else vm.public_ip
        method = "gcloud" if vm.ssh_method == "gcloud" else "ssh -i"
        print(f"  {C.CYAN}{i}{C.RESET}) {vm.name:<18} {vm.alias:<10} {ip:<16} ({method})")
    print()


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
    subprocess.run(["fusermount", "-uz", str(mp)], capture_output=True, timeout=5)
    time.sleep(0.3)
    try:
        if mp.exists():
            list(mp.iterdir())
    except OSError:
        subprocess.run(["fusermount", "-uz", str(mp)], capture_output=True, timeout=5)
        time.sleep(0.5)
        subprocess.run(["umount", "-l", str(mp)], capture_output=True, timeout=5)


def mount_vm(vm: VM, use_wg: bool = True, verbose: bool = False) -> tuple[bool, str]:
    """Mount a VM via SSHFS."""
    mp = mount_point(vm)
    if is_mounted(vm):
        return True, ""
    clean_stale_mount(mp)
    mp.mkdir(parents=True, exist_ok=True)

    ips_to_try = []
    if use_wg:
        ips_to_try.append(("WG", vm.wg_ip))
    ips_to_try.append(("Public", vm.public_ip))

    last_err = ""
    for ip_type, ip in ips_to_try:
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
            print(f"{C.RED}FAIL{C.RESET}" + (f" - {err}" if err else ""))


def unmount_all() -> None:
    print(f"\n{C.BOLD}Unmounting all VMs...{C.RESET}")
    for vm in VMS:
        ok = unmount_vm(vm)
        s = f"{C.GREEN}OK{C.RESET}" if ok else f"{C.RED}FAIL{C.RESET}"
        print(f"  {vm.name}: {s}")


# ============================================================================
# VAULT FUNCTIONS
# ============================================================================

def vault_installed() -> bool:
    code, _, _ = run(["which", "bw"])
    return code == 0


def vault_status() -> dict:
    """Get Bitwarden vault status."""
    result = {"installed": False, "logged_in": False, "locked": True, "email": ""}

    if not vault_installed():
        return result
    result["installed"] = True

    code, out, _ = run(["bw", "status"], timeout=5)
    if code != 0:
        return result

    try:
        status = json.loads(out)
        result["logged_in"] = status.get("status") != "unauthenticated"
        result["locked"] = status.get("status") == "locked"
        result["email"] = status.get("userEmail", "")
    except:
        pass

    return result


def vault_unlock() -> bool:
    """Unlock the vault."""
    status = vault_status()
    if not status["installed"]:
        print(f"  {C.RED}Bitwarden CLI not installed{C.RESET}")
        print(f"  Install: sudo pacman -S bitwarden-cli")
        return False

    if not status["logged_in"]:
        print(f"  {C.YELLOW}Not logged in. Running bw login...{C.RESET}")
        return run_interactive(["bw", "login"]) == 0

    if status["locked"]:
        print(f"  {C.YELLOW}Vault locked. Running bw unlock...{C.RESET}")
        return run_interactive(["bw", "unlock"]) == 0

    print(f"  {C.GREEN}Vault already unlocked{C.RESET}")
    return True


def vault_lock() -> bool:
    """Lock the vault."""
    code, _, _ = run(["bw", "lock"], timeout=5)
    if code == 0:
        print(f"  {C.GREEN}Vault locked{C.RESET}")
        return True
    print(f"  {C.RED}Failed to lock vault{C.RESET}")
    return False


def vault_sync() -> bool:
    """Sync the vault."""
    print(f"  Syncing vault...")
    code, _, _ = run(["bw", "sync"], timeout=30)
    if code == 0:
        print(f"  {C.GREEN}Vault synced{C.RESET}")
        return True
    print(f"  {C.RED}Sync failed{C.RESET}")
    return False


# ============================================================================
# SETUP FUNCTIONS
# ============================================================================

def check_ssh_setup() -> dict:
    """Check SSH setup status."""
    checks = {
        "ssh_dir": (HOME / ".ssh").exists(),
        "id_rsa": (HOME / ".ssh/id_rsa").exists() or SSH_KEY_OCI.exists(),
        "gcp_key": SSH_KEY_GCP.exists(),
        "agent_running": False,
        "key_loaded": False,
    }

    code, out, _ = run(["ssh-add", "-l"])
    checks["agent_running"] = code != 2  # 2 means agent not running
    checks["key_loaded"] = code == 0 and "id_rsa" in out

    return checks


def check_vpn_setup() -> dict:
    """Check VPN setup status."""
    keys_ok, pub_key = wg_keys_exist()
    return {
        "tools_installed": wg_tools_installed(),
        "keys_exist": keys_ok,
        "public_key": pub_key,
        "config_exists": wg_config_exists(),
    }


def check_mount_setup() -> dict:
    """Check mount setup status."""
    code_fuse, _, _ = run(["which", "fusermount"])
    code_sshfs, _, _ = run(["which", "sshfs"])
    code_groups, out, _ = run(["groups"])

    return {
        "fuse_installed": code_fuse == 0,
        "sshfs_installed": code_sshfs == 0,
        "user_in_fuse_group": "fuse" in out,
        "mount_base_exists": MOUNT_BASE.exists(),
    }


def print_setup_status() -> None:
    """Print full setup status."""
    ssh = check_ssh_setup()
    vpn = check_vpn_setup()
    mnt = check_mount_setup()
    vlt = vault_status()

    def status(ok: bool) -> str:
        return f"{C.GREEN}OK{C.RESET}" if ok else f"{C.RED}--{C.RESET}"

    print(f"\n{C.BOLD}=== SETUP & DIAGNOSTICS ==={C.RESET}\n")

    print(f"  {C.CYAN}SSH SETUP{C.RESET}")
    print(f"    ~/.ssh exists:          {status(ssh['ssh_dir'])}")
    print(f"    SSH key (OCI):          {status(ssh['id_rsa'])}")
    print(f"    SSH key (GCP):          {status(ssh['gcp_key'])}")
    print(f"    ssh-agent running:      {status(ssh['agent_running'])}")
    print(f"    Key loaded in agent:    {status(ssh['key_loaded'])}")

    print(f"\n  {C.CYAN}VPN SETUP{C.RESET}")
    print(f"    WireGuard tools:        {status(vpn['tools_installed'])}")
    print(f"    Keys generated:         {status(vpn['keys_exist'])}")
    print(f"    Config installed:       {status(vpn['config_exists'])}")

    print(f"\n  {C.CYAN}MOUNT SETUP{C.RESET}")
    print(f"    FUSE installed:         {status(mnt['fuse_installed'])}")
    print(f"    SSHFS installed:        {status(mnt['sshfs_installed'])}")
    print(f"    User in fuse group:     {status(mnt['user_in_fuse_group'])}")
    print(f"    Mount base exists:      {status(mnt['mount_base_exists'])}")

    print(f"\n  {C.CYAN}VAULT SETUP{C.RESET}")
    print(f"    Bitwarden CLI:          {status(vlt['installed'])}")
    print(f"    Logged in:              {status(vlt['logged_in'])}")
    print(f"    Unlocked:               {status(not vlt['locked'])}")
    if vlt['email']:
        print(f"    User:                   {C.DIM}{vlt['email']}{C.RESET}")

    print()


def fix_ssh() -> bool:
    """Fix SSH setup."""
    print(f"\n{C.BOLD}Fixing SSH...{C.RESET}")

    # Ensure ~/.ssh exists
    ssh_dir = HOME / ".ssh"
    if not ssh_dir.exists():
        ssh_dir.mkdir(mode=0o700)
        print(f"  Created {ssh_dir}")

    # Start ssh-agent if needed
    code, _, _ = run(["ssh-add", "-l"])
    if code == 2:
        print(f"  {C.YELLOW}Starting ssh-agent...{C.RESET}")
        os.system('eval "$(ssh-agent -s)"')

    # Add keys to agent
    if SSH_KEY_OCI.exists():
        code, _, _ = run(["ssh-add", str(SSH_KEY_OCI)])
        if code == 0:
            print(f"  {C.GREEN}Added OCI key to agent{C.RESET}")

    if SSH_KEY_GCP.exists():
        code, _, _ = run(["ssh-add", str(SSH_KEY_GCP)])
        if code == 0:
            print(f"  {C.GREEN}Added GCP key to agent{C.RESET}")

    return True


def fix_mount() -> bool:
    """Fix mount setup."""
    print(f"\n{C.BOLD}Fixing Mount...{C.RESET}")

    if not MOUNT_BASE.exists():
        MOUNT_BASE.mkdir(parents=True, exist_ok=True)
        print(f"  {C.GREEN}Created {MOUNT_BASE}{C.RESET}")

    # Create subdirs for each VM
    for vm in VMS:
        mp = mount_point(vm)
        if not mp.exists():
            mp.mkdir(parents=True, exist_ok=True)
            print(f"  Created {mp}")

    return True


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
        "vault": vault_status(),
        "vms": {}
    }

    if status["vpn_up"]:
        status["vpn_handshake"] = vpn_has_handshake()
        status["vpn_transfer"] = vpn_get_transfer()

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

    with ThreadPoolExecutor(max_workers=6) as ex:
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


def get_mount_count(status: dict) -> tuple[int, int]:
    """Get (mounted, total) count."""
    mounted = sum(1 for v in status["vms"].values() if v.get("mounted"))
    return mounted, len(VMS)


# ============================================================================
# TUI DISPLAY
# ============================================================================

def print_header():
    """Print header."""
    print(f"\n{C.BOLD}{C.CYAN}{box_top()}")
    print(box_line(f"CLOUD CONNECT v{VERSION}"))
    print(box_line("VPN - SSH - Mount - Vault"))
    print(f"{box_bot()}{C.RESET}")


def print_topology(status: dict) -> None:
    """Print network topology."""
    vpn_up = status["vpn_up"]
    vms = status["vms"]
    tmode = status.get("tunnel_mode", "unknown")

    vpn_color = C.GREEN if vpn_up else C.RED
    vpn_status = f"CONNECTED ({tmode})" if vpn_up else "DISCONNECTED"

    print(f"""
                              {C.CYAN}INTERNET{C.RESET}
                                  |
         +------------------------+------------------------+
         |                        |                        |
    +---------+            +-----------+            +---------+
    |{C.MAGENTA}OCI Dev{C.RESET}  |            | {C.CYAN}GCP Hub{C.RESET}  |            |{C.MAGENTA}OCI Web{C.RESET} |
    |{vms.get('dev',{}).get('public_ip','--')[:11]:^9}|            |{vms.get('gcp',{}).get('public_ip','--')[:11]:^11}|            |{vms.get('web',{}).get('public_ip','--')[:11]:^9}|
    +----+----+            +-----+-----+            +----+----+
         |                       |                       |
         +-----------------------+-----------------------+
                     WireGuard VPN (10.0.0.0/24)
                        {vpn_color}{vpn_status:^24}{C.RESET}
                                 |
              +------------------+------------------+
              |                  |                  |
         +--------+        +---------+        +----------+
         |10.0.0.4|        |{C.GREEN}10.0.0.5{C.RESET} |        |{C.MAGENTA}OCI Svcs{C.RESET} |
         |OCI Svc |        | {C.GREEN}LOCAL{C.RESET}   |        |{vms.get('services',{}).get('public_ip','--')[:10]:^10}|
         +--------+        +---------+        +----------+
""")


def print_status_bar(status: dict) -> None:
    """Print compact status bar."""
    vpn_up = status["vpn_up"]
    tmode = status.get("tunnel_mode", "?")
    rx, tx = status["vpn_transfer"]
    mounted, total = get_mount_count(status)
    vault = status.get("vault", {})

    vpn_s = f"{C.GREEN}UP ({tmode}){C.RESET}" if vpn_up else f"{C.RED}DOWN{C.RESET}"
    vault_s = f"{C.GREEN}unlocked{C.RESET}" if vault.get("installed") and not vault.get("locked") else f"{C.RED}locked{C.RESET}"

    print(f"{C.BOLD}{box_top()}")
    print(box_line(f"VPN: {vpn_s}  |  Transfer: {rx}/{tx}  |  Mounts: {mounted}/{total}  |  Vault: {vault_s}"))
    print(f"{box_bot()}{C.RESET}")


def print_vm_table(status: dict) -> None:
    """Print VM status table."""
    print(f"\n{C.BOLD}  VM STATUS{C.RESET}")
    print(f"  {'VM':<18} {'WG IP':<12} {'Public IP':<16} {'WG':<8} {'Pub':<8} {'Mnt'}")
    print(f"  {'-'*70}")

    for vm in VMS:
        d = status["vms"].get(vm.alias, {})
        wg_p = f"{C.GREEN}{d.get('wg_latency',0):.0f}ms{C.RESET}" if d.get('wg_ping') else f"{C.DIM}--{C.RESET}"
        pub_p = f"{C.GREEN}{d.get('pub_latency',0):.0f}ms{C.RESET}" if d.get('pub_ping') else f"{C.DIM}--{C.RESET}"
        mnt = f"{C.GREEN}*{C.RESET}" if d.get('mounted') else f"{C.DIM}o{C.RESET}"
        print(f"  {vm.name:<18} {vm.wg_ip:<12} {vm.public_ip:<16} {wg_p:<16} {pub_p:<16} {mnt}")


def print_actions_panel() -> None:
    """Print actions panel."""
    print(f"""
{C.BOLD}  ACTIONS{C.RESET}

  {C.CYAN}VPN{C.RESET}                 {C.CYAN}SSH{C.RESET}                 {C.CYAN}MOUNT{C.RESET}               {C.CYAN}OTHER{C.RESET}
  v) up               1) gcp               m) mount all        b) vault
  d) down             2) dev               u) unmount all      x) setup
  t) toggle mode      3) web               a) mount (pub IP)   r) refresh
  f) full tunnel      4) services                              q) quit
  p) split tunnel                          !) gcp  @) dev
  s) vpn setup                             #) web  $) services
""")


def print_help() -> None:
    """Print help screen."""
    print(f"""
{C.BOLD}{C.CYAN}{box_top()}
{box_line("CLOUD CONNECT v" + VERSION)}
{box_line("VPN - SSH - Mount - Vault Manager")}
{box_bot()}{C.RESET}

{C.BOLD}USAGE:{C.RESET}
    cloud_connect.py              Open interactive TUI
    cloud_connect.py status       Show detailed status
    cloud_connect.py ssh <alias>  SSH to VM (gcp, dev, web, services)
    cloud_connect.py ssh list     List SSH hosts
    cloud_connect.py vpn up|down  Connect/disconnect VPN
    cloud_connect.py vpn setup    Setup WireGuard
    cloud_connect.py vpn split|full  Set tunnel mode
    cloud_connect.py mount        Mount all VMs
    cloud_connect.py unmount      Unmount all VMs
    cloud_connect.py vault        Open vault manager
    cloud_connect.py setup        Run setup diagnostics
    cloud_connect.py daemon       Run auto-reconnect daemon

{C.BOLD}TUI KEYS:{C.RESET}
    v  VPN up          d  VPN down         t  Toggle tunnel
    f  Full tunnel     p  Split tunnel     s  VPN setup
    1-4  SSH to VM     m  Mount all        u  Unmount all
    a  Mount (pub IP)  !@#$ Toggle mount   b  Vault menu
    x  Setup menu      r  Refresh          q  Quit

{C.BOLD}VMs:{C.RESET}
    1) gcp       GCP Hub          34.55.55.234    10.0.0.1
    2) dev       Oracle Dev       84.235.234.87   10.0.0.2
    3) web       Oracle Web       130.110.251.193 10.0.0.3
    4) services  Oracle Services  129.151.228.66  10.0.0.4
""")


# ============================================================================
# TUI MAIN LOOP
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

        print_header()
        print_topology(status)
        print_status_bar(status)
        print_vm_table(status)
        print_actions_panel()

        try:
            choice = input(f"  {C.BOLD}>{C.RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            break

        if choice == 'q':
            break
        elif choice == '?':
            clear_screen()
            print_help()
            input("\n  Press Enter...")
        elif choice == 'v':
            vpn_up()
            time.sleep(2)
        elif choice in ('d', 'V'):
            vpn_down()
            time.sleep(1)
        elif choice == 't':
            new_mode = "full" if status.get("tunnel_mode") == "split" else "split"
            set_tunnel_mode(new_mode)
            time.sleep(2)
        elif choice == 'f':
            set_tunnel_mode("full")
            time.sleep(2)
        elif choice == 'p':
            set_tunnel_mode("split")
            time.sleep(2)
        elif choice == 's':
            vpn_setup()
            input("\n  Press Enter...")
        elif choice in ('1', '2', '3', '4'):
            vm = VMS[int(choice) - 1]
            ssh_to_vm(vm, use_wg=status["vpn_up"])
        elif choice == 'm':
            mount_all(use_wg=status["vpn_up"])
            time.sleep(1)
        elif choice in ('u', 'M'):
            unmount_all()
            time.sleep(1)
        elif choice == 'a':
            mount_all(use_wg=False)
            time.sleep(1)
        elif choice in ('!', '@', '#', '$'):
            idx = {'!': 0, '@': 1, '#': 2, '$': 3}[choice]
            vm = VMS[idx]
            if is_mounted(vm):
                unmount_vm(vm)
                print(f"  {vm.name}: Unmounted")
            else:
                ok, err = mount_vm(vm, use_wg=status["vpn_up"])
                if ok:
                    print(f"  {vm.name}: {C.GREEN}Mounted{C.RESET}")
                else:
                    print(f"  {vm.name}: {C.RED}Failed{C.RESET}")
            time.sleep(1)
        elif choice == 'b':
            clear_screen()
            print(f"\n{C.BOLD}=== VAULT ==={C.RESET}\n")
            vst = vault_status()
            if not vst["installed"]:
                print(f"  {C.RED}Bitwarden CLI not installed{C.RESET}")
            else:
                print(f"  Status: {'Unlocked' if not vst['locked'] else 'Locked'}")
                print(f"  User: {vst['email'] or 'Not logged in'}")
                print(f"\n  [u] Unlock  [l] Lock  [s] Sync  [b] Back")
                sub = input(f"\n  {C.BOLD}>{C.RESET} ").strip()
                if sub == 'u':
                    vault_unlock()
                elif sub == 'l':
                    vault_lock()
                elif sub == 's':
                    vault_sync()
            input("\n  Press Enter...")
        elif choice == 'x':
            clear_screen()
            print_setup_status()
            print(f"  [1] Fix SSH  [2] Fix VPN  [3] Fix Mount  [a] Fix All  [b] Back")
            sub = input(f"\n  {C.BOLD}>{C.RESET} ").strip()
            if sub == '1':
                fix_ssh()
            elif sub == '2':
                vpn_setup()
            elif sub == '3':
                fix_mount()
            elif sub == 'a':
                fix_ssh()
                vpn_setup()
                fix_mount()
            input("\n  Press Enter...")
        elif choice == 'r':
            continue

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

    if cmd in ["-h", "--help", "help", "?"]:
        print_help()
        status = get_full_status()
        print_topology(status)

    elif cmd == "status":
        status = get_full_status()
        print_header()
        print_topology(status)
        print_status_bar(status)
        print_vm_table(status)

    elif cmd == "ssh":
        if len(sys.argv) < 3:
            ssh_list()
            return
        sub = sys.argv[2].lower()
        if sub == "list":
            ssh_list()
        else:
            vm = find_vm(sub)
            if vm:
                ssh_to_vm(vm, use_wg=vpn_is_up())
            else:
                print(f"{C.RED}Unknown VM: {sub}{C.RESET}")
                ssh_list()

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

    elif cmd == "mount":
        if len(sys.argv) >= 3:
            sub = sys.argv[2].lower()
            if sub == "all":
                mount_all(use_wg=vpn_is_up())
            else:
                vm = find_vm(sub)
                if vm:
                    ok, err = mount_vm(vm, use_wg=vpn_is_up())
                    if ok:
                        print(f"{C.GREEN}Mounted {vm.name}{C.RESET}")
                    else:
                        print(f"{C.RED}Failed: {err}{C.RESET}")
                else:
                    print(f"{C.RED}Unknown VM: {sub}{C.RESET}")
        else:
            mount_all(use_wg=vpn_is_up())

    elif cmd == "unmount":
        if len(sys.argv) >= 3:
            sub = sys.argv[2].lower()
            if sub == "all":
                unmount_all()
            else:
                vm = find_vm(sub)
                if vm:
                    if unmount_vm(vm):
                        print(f"{C.GREEN}Unmounted {vm.name}{C.RESET}")
                    else:
                        print(f"{C.RED}Failed to unmount {vm.name}{C.RESET}")
                else:
                    print(f"{C.RED}Unknown VM: {sub}{C.RESET}")
        else:
            unmount_all()

    elif cmd == "vault":
        if len(sys.argv) >= 3:
            sub = sys.argv[2].lower()
            if sub == "status":
                vst = vault_status()
                print(f"Installed: {vst['installed']}")
                print(f"Logged in: {vst['logged_in']}")
                print(f"Unlocked: {not vst['locked']}")
                print(f"Email: {vst['email']}")
            elif sub == "unlock":
                vault_unlock()
            elif sub == "lock":
                vault_lock()
            elif sub == "sync":
                vault_sync()
        else:
            vault_unlock()

    elif cmd == "setup":
        if len(sys.argv) >= 3:
            sub = sys.argv[2].lower()
            if sub == "ssh":
                fix_ssh()
            elif sub == "vpn":
                vpn_setup()
            elif sub == "mount":
                fix_mount()
            else:
                print_setup_status()
        else:
            print_setup_status()

    elif cmd == "daemon":
        daemon()

    else:
        print(f"Unknown: {cmd}")
        print("Use --help for usage")
        sys.exit(1)


if __name__ == "__main__":
    main()
