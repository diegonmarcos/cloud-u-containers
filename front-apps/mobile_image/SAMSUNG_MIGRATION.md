# Samsung Apps Migration to BlissOS VM

## Overview

This guide covers mirroring Samsung device apps and configs to a BlissOS virtual machine.

## Prerequisites

- Samsung device with USB debugging enabled
- ADB installed: `sudo pacman -S android-tools`
- BlissOS VM running and configured

---

## Method 1: Samsung Smart Switch Backup (Recommended)

### On Samsung Device

1. **Settings > Accounts > Backup > Smart Switch**
2. Backup to SD card or external storage
3. Transfer backup folder to `shared/` directory

### In BlissOS VM

1. Mount shared folder (virtiofs)
2. Use file manager to access backup
3. Restore via Smart Switch app (if available) or manually

---

## Method 2: ADB App Extraction

### Extract APKs from Samsung

```bash
# Connect Samsung via USB (USB debugging ON)
adb devices

# List installed packages
adb shell pm list packages -3 | cut -d: -f2 > samsung_apps.txt

# Extract APKs
mkdir -p shared/apks
while read pkg; do
    path=$(adb shell pm path "$pkg" | cut -d: -f2 | tr -d '\r')
    adb pull "$path" "shared/apks/${pkg}.apk"
done < samsung_apps.txt
```

### Install in BlissOS

```bash
# Connect to BlissOS VM via ADB
adb connect <vm-ip>:5555

# Install all APKs
for apk in shared/apks/*.apk; do
    adb install "$apk"
done
```

---

## Method 3: Titanium Backup (Root Required)

If Samsung device is rooted:

1. Use Titanium Backup to create full app+data backups
2. Copy TitaniumBackup folder to `shared/`
3. Install Titanium Backup in BlissOS (also needs root)
4. Restore apps with data

---

## App Data Sync Options

### For Apps with Cloud Sync

| App Type | Sync Method |
|----------|-------------|
| Google Apps | Sign in with same Google account |
| Samsung Apps | Samsung account (limited support) |
| Social Media | Login syncs data |
| Banking Apps | Usually won't work (SafetyNet) |

### For Apps without Cloud Sync

Use `adb backup` for individual apps:

```bash
# Backup app data (Samsung)
adb backup -f shared/app_backup.ab -apk -shared com.example.app

# Restore in BlissOS
adb restore shared/app_backup.ab
```

---

## Samsung-Specific Considerations

### Apps That Won't Work

- **Samsung Pay** - Hardware security required
- **Samsung Health** - Samsung hardware sensors
- **Samsung Pass** - Knox/biometric tied
- **Secure Folder apps** - Knox encrypted

### Apps That Should Work

- **Samsung Notes** - Export to PDF/text first
- **Samsung Gallery** - Export photos to shared folder
- **Samsung Internet** - Sync via Samsung account
- **Samsung Calendar** - Export .ics, import in BlissOS

### Workarounds

| Samsung App | BlissOS Alternative |
|-------------|---------------------|
| Samsung Notes | Google Keep, Notion |
| Samsung Health | Google Fit |
| Samsung Pay | Google Pay |
| Samsung Calendar | Google Calendar |
| Bixby Routines | Tasker |

---

## VM Network Setup for ADB

### Enable ADB in BlissOS

1. Settings > About > Tap "Build number" 7 times
2. Settings > Developer Options > Enable "USB debugging"
3. Settings > Developer Options > Enable "ADB over network"

### Connect from Host

```bash
# Find VM IP
virsh domifaddr blissos-samsung

# Connect ADB
adb connect <vm-ip>:5555

# Verify
adb devices
```

---

## Shared Folder Access in BlissOS

The VM is configured with virtiofs shared folder.

### Mount in BlissOS (as root)

```bash
# In BlissOS terminal (Alt+F1 for console)
su
mkdir -p /mnt/shared
mount -t virtiofs shared /mnt/shared
```

### Permanent Mount

Add to `/etc/fstab`:
```
shared /mnt/shared virtiofs defaults 0 0
```

---

## SafetyNet / Play Integrity

Some apps check device integrity. BlissOS may fail these checks.

### Solutions

1. **Magisk + Universal SafetyNet Fix** (if rooted)
2. **microG** instead of Google Play Services
3. **Accept limitations** for banking/secure apps

---

## Quick Reference

```bash
# Extract all user apps from Samsung
./extract-samsung-apps.sh

# Push to BlissOS shared folder
cp -r samsung_apps/* shared/

# Batch install in BlissOS
./install-apps.sh
```

---

## Files Structure

```
mobile_image/
├── BlissOS-16.9.7-gapps.iso    # BlissOS installer
├── blissos-samsung.qcow2       # VM disk
├── blissos-vm.xml              # libvirt config
├── setup.sh                    # VM management script
├── OVMF_VARS.fd                # UEFI variables
├── shared/                     # Host <-> VM shared folder
│   ├── apks/                   # Extracted APKs
│   ├── backups/                # App data backups
│   └── media/                  # Photos, documents
└── SAMSUNG_MIGRATION.md        # This guide
```
