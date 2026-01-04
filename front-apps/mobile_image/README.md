# BlissOS VM - Samsung Apps Mirror

A QEMU/KVM virtual machine running BlissOS (Android x86) to mirror and run Samsung device apps on desktop.

## Overview

| Component | Details |
|-----------|---------|
| **OS** | BlissOS 16.9.7 (Android 13) |
| **Google Play** | Included (GApps build) |
| **Virtualization** | QEMU/KVM with libvirt |
| **Host** | Arch Linux |
| **Purpose** | Mirror Samsung apps and configs |

## Why BlissOS?

- Full Android x86 with Play Store support
- Official QEMU/KVM support (unlike VirtualBox/VMware)
- Tablet UI works well for desktop use
- Can run most Android apps (ARM translated via libhoudini)

---

## Quick Start

```bash
# 1. Start libvirt (one time)
sudo systemctl enable --now libvirtd

# 2. Run setup
./setup.sh setup

# 3. Start VM and install BlissOS
./setup.sh start
```

---

## File Structure

```
mobile_image/
├── BlissOS-16.9.7-gapps.iso    # BlissOS installer ISO (~2.2GB)
├── blissos-samsung.qcow2       # VM disk image (created by setup)
├── blissos-vm.xml              # libvirt VM definition
├── OVMF_VARS.fd                # UEFI variables (created by setup)
├── setup.sh                    # VM management script
├── extract-samsung-apps.sh     # Extract APKs from Samsung device
├── install-apps.sh             # Install APKs into BlissOS VM
├── SAMSUNG_MIGRATION.md        # Detailed migration guide
├── README.md                   # This file
└── shared/                     # Shared folder (host <-> VM)
    ├── apks/                   # Extracted APKs
    └── backups/                # App data backups
```

---

## VM Specifications

| Resource | Value |
|----------|-------|
| RAM | 4 GB |
| CPU | 4 cores (host passthrough) |
| Disk | 32 GB (qcow2, thin provisioned) |
| Graphics | Virtio GPU with 3D acceleration |
| Network | NAT (libvirt default) |
| Boot | UEFI (OVMF) |
| Shared Folder | virtiofs mount |

---

## Prerequisites

### Required Packages

```bash
# Arch Linux
sudo pacman -S qemu-full libvirt virt-manager edk2-ovmf android-tools

# Enable libvirt
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER  # Then re-login
```

### Verify Installation

```bash
# Check KVM support
lsmod | grep kvm

# Check libvirt
virsh list --all

# Check UEFI firmware
ls /usr/share/edk2/x64/OVMF_CODE.4m.fd
```

---

## Setup Guide

### Step 1: Download BlissOS

ISO should already be present. If not:

```bash
wget -O BlissOS-16.9.7-gapps.iso \
  "https://sourceforge.net/projects/blissos-x86/files/Official/BlissOS16/Gapps/Generic/Bliss-v16.9.7-x86_64-OFFICIAL-gapps-20240911.iso/download"
```

### Step 2: Create VM

```bash
./setup.sh setup
```

This will:
- Check prerequisites
- Create 32GB virtual disk
- Copy UEFI NVRAM template
- Define VM in libvirt

### Step 3: Install BlissOS

```bash
./setup.sh start
```

In the BlissOS installer:

1. Select **"Installation - Install Bliss-OS to harddisk"**
2. Select **"Create/Modify partitions"** → GPT → Yes
3. Create partition: New → Primary → Full size → Write → Quit
4. Select the partition (sda1)
5. Format as **ext4**
6. Install **GRUB bootloader** → Yes
7. **Do NOT** install as system read-write (select No)
8. Reboot

### Step 4: Post-Install Configuration

After BlissOS boots:

1. Complete Android setup wizard
2. Sign in with Google account (for Play Store)
3. **Enable Developer Options:**
   - Settings → About tablet → Tap "Build number" 7 times
4. **Enable ADB over network:**
   - Settings → Developer options → ADB over network → On
5. Note the IP address shown

---

## VM Management

```bash
./setup.sh setup     # Initial setup (create disk, define VM)
./setup.sh start     # Start VM and open viewer
./setup.sh stop      # Graceful shutdown
./setup.sh destroy   # Force stop
./setup.sh status    # Show VM info
./setup.sh console   # Open virt-viewer
```

### Alternative: virt-manager GUI

```bash
virt-manager
```

---

## Samsung App Migration

### Method 1: Extract via ADB (Recommended)

Connect Samsung device with USB debugging enabled:

```bash
# Extract all user apps from Samsung
./extract-samsung-apps.sh

# Install into BlissOS
./install-apps.sh <blissos-ip>
# or auto-detect:
./install-apps.sh
```

### Method 2: Manual APK Transfer

1. On Samsung: Use APK Extractor app
2. Transfer APKs to `shared/apks/`
3. In BlissOS: Access shared folder and install

### Method 3: Play Store

Simply download apps from Play Store in BlissOS using the same Google account.

---

## Shared Folder

The VM has a virtiofs shared folder configured.

### Mount in BlissOS

```bash
# Open terminal in BlissOS (Alt+F1 or terminal app)
su
mkdir -p /mnt/shared
mount -t virtiofs shared /mnt/shared
```

### Permanent Mount

Add to BlissOS `/etc/fstab`:
```
shared /mnt/shared virtiofs defaults 0 0
```

---

## ADB Connection

### From Host to BlissOS VM

```bash
# Get VM IP
virsh domifaddr blissos-samsung

# Connect
adb connect <vm-ip>:5555

# Verify
adb devices

# Shell access
adb shell
```

### From Host to Samsung Device

```bash
# USB connection
adb devices

# Wireless (same network)
adb tcpip 5555
adb connect <samsung-ip>:5555
```

---

## Troubleshooting

### VM Won't Start

```bash
# Check libvirt status
sudo systemctl status libvirtd

# Check VM logs
virsh dumpxml blissos-samsung
journalctl -u libvirtd -f
```

### No Network in BlissOS

```bash
# Ensure default network is running
virsh net-start default
virsh net-autostart default
```

### Graphics Issues

Edit `blissos-vm.xml` and try different video options:

```xml
<!-- Option 1: Virtio (best performance) -->
<video>
  <model type='virtio' heads='1' primary='yes'>
    <acceleration accel3d='yes'/>
  </model>
</video>

<!-- Option 2: QXL (better compatibility) -->
<video>
  <model type='qxl' ram='65536' vram='65536' heads='1'/>
</video>
```

### Apps Crash / Won't Install

- **ARM-only apps**: Some apps don't have x86 binaries and libhoudini translation may fail
- **SafetyNet failures**: Banking apps may detect VM environment
- **Split APKs**: Use `adb install-multiple` for apps with multiple APK files

### Slow Performance

1. Ensure KVM is enabled (not TCG emulation)
2. Increase RAM in XML config
3. Enable 3D acceleration in video settings
4. Use virtio drivers for disk and network

---

## App Compatibility

### Works Well

- Social media (Instagram, Twitter, TikTok)
- Messaging (WhatsApp, Telegram, Signal)
- Productivity (Office, Google apps)
- Entertainment (YouTube, Netflix, Spotify)
- Games (casual, some 3D)

### Limited / Won't Work

| App Type | Issue |
|----------|-------|
| Banking apps | SafetyNet/Play Integrity fails |
| Samsung Pay | Hardware security required |
| Samsung Health | Requires Samsung sensors |
| Camera apps | No camera in VM |
| AR apps | No gyroscope/accelerometer |

### Workarounds

- **Magisk + SafetyNet Fix**: For root + passing SafetyNet
- **microG**: Replace Google Play Services (privacy focused)
- **USB passthrough**: Connect physical devices to VM

---

## Backup & Restore

### Backup VM

```bash
# Shutdown VM first
./setup.sh stop

# Backup disk image
cp blissos-samsung.qcow2 blissos-samsung.qcow2.backup

# Or create snapshot
virsh snapshot-create-as blissos-samsung snap1 "Initial setup"
```

### Restore VM

```bash
# From backup
cp blissos-samsung.qcow2.backup blissos-samsung.qcow2

# From snapshot
virsh snapshot-revert blissos-samsung snap1
```

---

## Resources

- [BlissOS Official](https://blissos.org/)
- [BlissOS Downloads](https://sourceforge.net/projects/blissos-x86/)
- [BlissOS GitHub](https://github.com/BlissRoms-x86)
- [BlissOS Telegram](https://t.me/blissx86)
- [libvirt Documentation](https://libvirt.org/docs.html)
- [QEMU Documentation](https://www.qemu.org/docs/master/)

---

## License

Personal use configuration. BlissOS is licensed under Apache 2.0.
