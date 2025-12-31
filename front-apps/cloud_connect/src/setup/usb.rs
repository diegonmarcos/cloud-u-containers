//! USB module - Create encrypted bootable Arch Linux USB with Docker KDE Desktop

use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::io::{self, Write};

const ARCH_MIRROR: &str = "https://geo.mirror.pkgbuild.com/iso/latest/";
const ARCH_ISO_PATTERN: &str = "archlinux-x86_64.iso";

// Embedded desktop files
const DOCKER_COMPOSE: &str = include_str!("../../assets/desktop/docker-compose.yml");
const DOCKERFILE: &str = include_str!("../../assets/desktop/Dockerfile");
const ENTRYPOINT_SH: &str = include_str!("../../assets/desktop/entrypoint.sh");
const FIRST_LOGIN_SH: &str = include_str!("../../assets/desktop/first-login.sh");

/// List available USB devices
pub async fn list_usb_devices() -> Result<()> {
    println!("{}", "Available USB Devices".bold().underline());
    println!();

    let output = Command::new("lsblk")
        .args(["-d", "-o", "NAME,SIZE,TRAN,MODEL,MOUNTPOINT", "-n"])
        .output()
        .context("Failed to run lsblk")?;

    if !output.status.success() {
        anyhow::bail!("Failed to list block devices");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut found_usb = false;

    println!("{:<12} {:<10} {:<10} {:<20} {}",
        "DEVICE".bold(), "SIZE".bold(), "TYPE".bold(), "MODEL".bold(), "MOUNTED".bold());
    println!("{}", "-".repeat(70));

    for line in stdout.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && parts[2] == "usb" {
            found_usb = true;
            let device = format!("/dev/{}", parts[0]);
            let size = parts[1];
            let model = if parts.len() >= 4 { parts[3] } else { "Unknown" };
            let mounted = if parts.len() >= 5 { parts[4] } else { "-" };

            println!("{:<12} {:<10} {:<10} {:<20} {}",
                device.cyan(), size, "USB", model, mounted);
        }
    }

    if !found_usb {
        println!("{}", "No USB devices found".yellow());
        println!();
        println!("Tips:");
        println!("  - Insert a USB drive (minimum 16GB recommended)");
        println!("  - Check if the USB is mounted (unmount first)");
    }

    println!();
    println!("{}", "WARNING: Creating a bootable USB will ERASE all data!".red());
    println!("{}", "The USB will be fully encrypted with LUKS.".cyan());

    Ok(())
}

/// Download latest Arch Linux ISO
pub async fn download_iso(output_dir: Option<PathBuf>) -> Result<PathBuf> {
    let out_dir = output_dir.unwrap_or_else(|| {
        std::env::var("HOME")
            .map(|h| PathBuf::from(h).join("Downloads"))
            .unwrap_or_else(|_| PathBuf::from("/tmp"))
    });

    std::fs::create_dir_all(&out_dir)?;

    println!("{}", "Downloading Arch Linux ISO".cyan());
    println!("  Mirror: {}", ARCH_MIRROR);
    println!("  Output: {}", out_dir.display());
    println!();

    // Get the latest ISO filename
    let iso_name = get_latest_iso_name().await?;
    let iso_path = out_dir.join(&iso_name);

    if iso_path.exists() {
        println!("{} ISO already exists: {}", "Info:".cyan(), iso_path.display());
        print!("Re-download? [y/N]: ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        if !input.trim().eq_ignore_ascii_case("y") {
            return Ok(iso_path);
        }
    }

    // Download ISO with progress
    println!("{}", "Downloading ISO (this may take a while)...".dimmed());
    let iso_url = format!("{}{}", ARCH_MIRROR, iso_name);

    let status = Command::new("curl")
        .args(["-L", "-#", "-o", iso_path.to_str().unwrap(), &iso_url])
        .status()
        .context("Failed to download ISO")?;

    if !status.success() {
        anyhow::bail!("Failed to download ISO");
    }

    println!("{} ISO downloaded: {}", "Success:".green(), iso_path.display());

    Ok(iso_path)
}

/// Get the latest ISO filename from the mirror
async fn get_latest_iso_name() -> Result<String> {
    let output = Command::new("curl")
        .args(["-s", "-L", ARCH_MIRROR])
        .output()
        .context("Failed to fetch mirror listing")?;

    let html = String::from_utf8_lossy(&output.stdout);

    for line in html.lines() {
        if line.contains("archlinux-") && line.contains("-x86_64.iso\"") && !line.contains(".sig") {
            if let Some(start) = line.find("archlinux-") {
                let rest = &line[start..];
                if let Some(end) = rest.find(".iso") {
                    let name = format!("{}.iso", &rest[..end]);
                    return Ok(name);
                }
            }
        }
    }

    Ok(ARCH_ISO_PATTERN.to_string())
}

/// Verify ISO checksum
pub async fn verify_iso(iso_path: &Path) -> Result<bool> {
    println!("{}", "Verifying ISO".cyan());
    println!("  File: {}", iso_path.display());
    println!();

    if !iso_path.exists() {
        anyhow::bail!("ISO file not found: {}", iso_path.display());
    }

    let checksum_url = format!("{}sha256sums.txt", ARCH_MIRROR);
    let output = Command::new("curl")
        .args(["-s", "-L", &checksum_url])
        .output()
        .context("Failed to download checksums")?;

    let checksums = String::from_utf8_lossy(&output.stdout);
    let iso_name = iso_path.file_name().unwrap().to_string_lossy();

    let mut expected_sum: Option<String> = None;
    for line in checksums.lines() {
        if line.contains(&*iso_name) {
            if let Some(sum) = line.split_whitespace().next() {
                expected_sum = Some(sum.to_string());
                break;
            }
        }
    }

    let expected = match expected_sum {
        Some(s) => s,
        None => {
            println!("{} Could not find checksum for this ISO", "Warning:".yellow());
            return Ok(false);
        }
    };

    println!("Expected: {}", expected.dimmed());
    print!("Computing: ");
    io::stdout().flush()?;

    let output = Command::new("sha256sum")
        .arg(iso_path)
        .output()
        .context("Failed to compute checksum")?;

    let computed = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_string();

    println!("{}", computed.dimmed());

    if computed == expected {
        println!("{} Checksum verified!", "Success:".green());
        Ok(true)
    } else {
        println!("{} Checksum mismatch!", "Error:".red());
        Ok(false)
    }
}

/// Create encrypted bootable USB with Docker KDE Desktop
pub async fn create_bootable_usb(
    device: &str,
    iso: Option<PathBuf>,
    _persist: bool,  // Always true for this setup
    persist_size: u32,
    yes: bool,
) -> Result<()> {
    // Validate device path
    if !device.starts_with("/dev/") {
        anyhow::bail!("Invalid device path. Use format: /dev/sdX");
    }

    if !Path::new(device).exists() {
        anyhow::bail!("Device not found: {}", device);
    }

    // Check if it's a USB device
    if !is_usb_device(device)? {
        println!("{} {} doesn't appear to be a USB device", "Warning:".yellow(), device);
        if !yes {
            print!("Continue anyway? [y/N]: ");
            io::stdout().flush()?;
            let mut input = String::new();
            io::stdin().read_line(&mut input)?;
            if !input.trim().eq_ignore_ascii_case("y") {
                return Ok(());
            }
        }
    }

    // Check device size (minimum 16GB recommended)
    let size_gb = get_device_size_gb(device)?;
    if size_gb < 8 {
        anyhow::bail!("Device too small. Minimum 8GB required, 16GB+ recommended. Found: {}GB", size_gb);
    }

    // Get or download ISO
    let iso_path = match iso {
        Some(p) => {
            if !p.exists() {
                anyhow::bail!("ISO not found: {}", p.display());
            }
            p
        }
        None => download_iso(None).await?,
    };

    // Final confirmation
    println!();
    println!("{}", "═".repeat(70).red());
    println!("{}", "  ENCRYPTED CLOUD DESKTOP USB CREATION".red().bold());
    println!("{}", "═".repeat(70).red());
    println!();
    println!("{}", "This will COMPLETELY ERASE the device and create:".yellow());
    println!("  • EFI boot partition (512MB)");
    println!("  • Arch Linux live system");
    println!("  • LUKS encrypted persistent partition ({}GB)", persist_size);
    println!("  • Docker KDE Desktop with Brave & Obsidian");
    println!();
    println!("Device:     {}", device.cyan());
    println!("Size:       {} GB", size_gb);
    println!("ISO:        {}", iso_path.display());
    println!("User:       diegonmarcos");
    println!("Password:   changeme (must change on first login)");
    println!("Encryption: LUKS2 (AES-256-XTS)");
    println!();
    println!("{}", "═".repeat(70).red());

    if !yes {
        println!();
        print!("{}", "Type 'YES' in capitals to confirm: ".red().bold());
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        if input.trim() != "YES" {
            println!("Aborted.");
            return Ok(());
        }
    }

    // Check for required tools
    check_required_tools()?;

    // Unmount device partitions
    println!();
    println!("{}", "Step 1/7: Unmounting device...".cyan().bold());
    unmount_device(device)?;

    // Wipe and partition the device
    println!("{}", "Step 2/7: Partitioning device...".cyan().bold());
    partition_device(device, persist_size).await?;

    // Write ISO to partition
    println!("{}", "Step 3/7: Writing Arch Linux ISO...".cyan().bold());
    write_iso_to_partition(device, &iso_path).await?;

    // Setup LUKS encryption on persistent partition
    println!("{}", "Step 4/7: Setting up LUKS encryption...".cyan().bold());
    println!();
    println!("{}", "You will be prompted to set the encryption passphrase.".yellow());
    println!("{}", "Choose a STRONG passphrase - this protects ALL your data!".yellow());
    println!();
    setup_luks_encryption(device).await?;

    // Format and setup persistent partition
    println!("{}", "Step 5/7: Setting up encrypted persistent storage...".cyan().bold());
    setup_persistent_storage(device).await?;

    // Install Docker desktop files
    println!("{}", "Step 6/7: Installing Docker KDE Desktop...".cyan().bold());
    install_desktop_files(device).await?;

    // Create boot configuration
    println!("{}", "Step 7/7: Configuring boot...".cyan().bold());
    configure_boot(device).await?;

    // Cleanup
    cleanup_mounts(device)?;

    println!();
    println!("{}", "═".repeat(70).green());
    println!("{}", "  ENCRYPTED CLOUD DESKTOP USB CREATED SUCCESSFULLY!".green().bold());
    println!("{}", "═".repeat(70).green());
    println!();
    println!("Boot instructions:");
    println!("  1. Reboot and enter BIOS/UEFI (F2, F12, Del, or Esc)");
    println!("  2. Select USB device to boot");
    println!("  3. Enter your LUKS encryption passphrase");
    println!("  4. Login: diegonmarcos / changeme");
    println!("  5. You MUST change password on first login");
    println!("  6. Docker KDE Desktop will start automatically");
    println!();
    println!("Desktop apps included:");
    println!("  • KDE Plasma Desktop");
    println!("  • Dolphin (Files), Konsole (Terminal), Kate (Editor)");
    println!("  • Brave Browser, Obsidian Notes");
    println!();

    Ok(())
}

/// Check required tools are installed
fn check_required_tools() -> Result<()> {
    let tools = ["parted", "cryptsetup", "mkfs.fat", "mkfs.ext4", "dd", "sync"];

    for tool in tools {
        if Command::new("which").arg(tool).output()?.status.success() {
            continue;
        }
        anyhow::bail!("Required tool '{}' not found. Install it first.", tool);
    }

    Ok(())
}

/// Unmount all partitions on device
fn unmount_device(device: &str) -> Result<()> {
    // Get all partitions
    let output = Command::new("lsblk")
        .args(["-ln", "-o", "NAME", device])
        .output()?;

    let partitions = String::from_utf8_lossy(&output.stdout);
    for part in partitions.lines() {
        let part_dev = format!("/dev/{}", part.trim());
        let _ = Command::new("sudo").args(["umount", "-f", &part_dev]).status();
    }

    // Close any LUKS devices
    let _ = Command::new("sudo").args(["cryptsetup", "close", "cloud-persist"]).status();

    // Wait for device to settle
    let _ = Command::new("sync").status();
    std::thread::sleep(std::time::Duration::from_secs(1));

    Ok(())
}

/// Partition the USB device
async fn partition_device(device: &str, persist_size: u32) -> Result<()> {
    // Wipe existing partition table
    let _ = Command::new("sudo")
        .args(["wipefs", "-a", device])
        .status();

    // Create GPT partition table
    run_sudo(&["parted", "-s", device, "mklabel", "gpt"])?;

    // Partition 1: EFI (512MB)
    run_sudo(&["parted", "-s", device, "mkpart", "EFI", "fat32", "1MiB", "513MiB"])?;
    run_sudo(&["parted", "-s", device, "set", "1", "esp", "on"])?;

    // Partition 2: Arch ISO (~1.2GB, but we'll use 2GB to be safe)
    run_sudo(&["parted", "-s", device, "mkpart", "ARCH", "513MiB", "2561MiB"])?;

    // Partition 3: Encrypted persistent (rest of the drive or specified size)
    let persist_end = if persist_size > 0 {
        format!("{}MiB", 2561 + (persist_size as u64 * 1024))
    } else {
        "100%".to_string()
    };
    run_sudo(&["parted", "-s", device, "mkpart", "PERSIST", "2561MiB", &persist_end])?;

    // Wait for partitions to appear
    let _ = Command::new("sudo").args(["partprobe", device]).status();
    std::thread::sleep(std::time::Duration::from_secs(2));

    // Format EFI partition
    let efi_part = get_partition_path(device, 1);
    run_sudo(&["mkfs.fat", "-F32", "-n", "EFI", &efi_part])?;

    println!("  Partitions created successfully");
    Ok(())
}

/// Write ISO to partition 2
async fn write_iso_to_partition(device: &str, iso_path: &Path) -> Result<()> {
    let arch_part = get_partition_path(device, 2);

    println!("  Writing ISO to {}...", arch_part);
    println!("  This may take several minutes...");

    let status = Command::new("sudo")
        .args([
            "dd",
            &format!("if={}", iso_path.display()),
            &format!("of={}", arch_part),
            "bs=4M",
            "status=progress",
            "oflag=sync",
        ])
        .status()
        .context("Failed to write ISO")?;

    if !status.success() {
        anyhow::bail!("Failed to write ISO to partition");
    }

    run_sudo(&["sync"])?;
    println!("  ISO written successfully");
    Ok(())
}

/// Setup LUKS encryption on partition 3
async fn setup_luks_encryption(device: &str) -> Result<()> {
    let persist_part = get_partition_path(device, 3);

    // Format with LUKS2
    let status = Command::new("sudo")
        .args([
            "cryptsetup", "luksFormat",
            "--type", "luks2",
            "--cipher", "aes-xts-plain64",
            "--key-size", "512",
            "--hash", "sha512",
            "--iter-time", "5000",
            "--label", "CLOUD-CRYPT",
            &persist_part,
        ])
        .status()
        .context("Failed to setup LUKS")?;

    if !status.success() {
        anyhow::bail!("LUKS encryption setup failed");
    }

    println!("  LUKS encryption configured");
    Ok(())
}

/// Setup the encrypted persistent storage
async fn setup_persistent_storage(device: &str) -> Result<()> {
    let persist_part = get_partition_path(device, 3);

    // Open LUKS volume
    println!("  Opening encrypted volume (enter passphrase)...");
    let status = Command::new("sudo")
        .args(["cryptsetup", "open", &persist_part, "cloud-persist"])
        .status()
        .context("Failed to open LUKS volume")?;

    if !status.success() {
        anyhow::bail!("Failed to open encrypted volume");
    }

    // Format as ext4
    run_sudo(&["mkfs.ext4", "-L", "CLOUD-PERSIST", "/dev/mapper/cloud-persist"])?;

    // Mount it
    run_sudo(&["mkdir", "-p", "/mnt/cloud-persist"])?;
    run_sudo(&["mount", "/dev/mapper/cloud-persist", "/mnt/cloud-persist"])?;

    // Create directory structure
    run_sudo(&["mkdir", "-p", "/mnt/cloud-persist/upper"])?;
    run_sudo(&["mkdir", "-p", "/mnt/cloud-persist/work"])?;
    run_sudo(&["mkdir", "-p", "/mnt/cloud-persist/docker"])?;
    run_sudo(&["mkdir", "-p", "/mnt/cloud-persist/home"])?;

    println!("  Persistent storage ready");
    Ok(())
}

/// Install Docker desktop files
async fn install_desktop_files(device: &str) -> Result<()> {
    let desktop_dir = "/mnt/cloud-persist/docker/desktop";

    // Create directory
    run_sudo(&["mkdir", "-p", desktop_dir])?;

    // Write docker-compose.yml
    write_file_as_root(&format!("{}/docker-compose.yml", desktop_dir), DOCKER_COMPOSE)?;

    // Write Dockerfile
    write_file_as_root(&format!("{}/Dockerfile", desktop_dir), DOCKERFILE)?;

    // Write entrypoint.sh
    write_file_as_root(&format!("{}/entrypoint.sh", desktop_dir), ENTRYPOINT_SH)?;
    run_sudo(&["chmod", "+x", &format!("{}/entrypoint.sh", desktop_dir)])?;

    // Write first-login.sh
    write_file_as_root(&format!("{}/first-login.sh", desktop_dir), FIRST_LOGIN_SH)?;
    run_sudo(&["chmod", "+x", &format!("{}/first-login.sh", desktop_dir)])?;

    // Create startup script
    let startup_script = r#"#!/bin/bash
# Cloud Desktop Auto-Start Script

# Wait for system
sleep 5

# Start Docker
systemctl start docker

# Navigate to desktop directory
cd /mnt/persist/docker/desktop

# Build and start the desktop
docker-compose up -d --build

echo "Cloud Desktop starting..."
echo "Connect via: docker exec -it cloud-desktop bash"
"#;

    write_file_as_root(&format!("{}/start-desktop.sh", desktop_dir), startup_script)?;
    run_sudo(&["chmod", "+x", &format!("{}/start-desktop.sh", desktop_dir)])?;

    println!("  Desktop files installed");
    Ok(())
}

/// Configure boot to use persistence
async fn configure_boot(device: &str) -> Result<()> {
    // Mount EFI partition
    let efi_part = get_partition_path(device, 1);
    run_sudo(&["mkdir", "-p", "/mnt/cloud-efi"])?;
    run_sudo(&["mount", &efi_part, "/mnt/cloud-efi"])?;

    // Create boot entry for persistence
    // This creates a custom boot loader entry that:
    // 1. Boots Arch ISO
    // 2. Unlocks LUKS
    // 3. Mounts persistence as overlay

    let loader_conf = r#"default archlinux.conf
timeout 5
console-mode max
editor no
"#;

    run_sudo(&["mkdir", "-p", "/mnt/cloud-efi/loader"])?;
    write_file_as_root("/mnt/cloud-efi/loader/loader.conf", loader_conf)?;

    let persist_part = get_partition_path(device, 3);
    let arch_entry = format!(r#"title   Cloud Desktop (Encrypted)
linux   /arch/boot/x86_64/vmlinuz-linux
initrd  /arch/boot/x86_64/initramfs-linux.img
options root=LABEL=ARCH_202* rw cryptdevice={}:cloud-persist:allow-discards rootflags=subvol=@ systemd.unit=multi-user.target
"#, persist_part);

    run_sudo(&["mkdir", "-p", "/mnt/cloud-efi/loader/entries"])?;
    write_file_as_root("/mnt/cloud-efi/loader/entries/archlinux.conf", &arch_entry)?;

    // Create persistence configuration
    let persist_conf = r#"# Cloud Desktop Persistence Configuration
# This file is read during boot to setup persistence

# Directories to overlay
/ union

# Docker data
/var/lib/docker source=docker

# Home directory
/home source=home
"#;

    write_file_as_root("/mnt/cloud-persist/persistence.conf", persist_conf)?;

    // Unmount EFI
    run_sudo(&["umount", "/mnt/cloud-efi"])?;

    println!("  Boot configuration complete");
    Ok(())
}

/// Cleanup mounts
fn cleanup_mounts(_device: &str) -> Result<()> {
    let _ = Command::new("sudo").args(["umount", "/mnt/cloud-persist"]).status();
    let _ = Command::new("sudo").args(["umount", "/mnt/cloud-efi"]).status();
    let _ = Command::new("sudo").args(["cryptsetup", "close", "cloud-persist"]).status();
    let _ = Command::new("sync").status();

    Ok(())
}

// Helper functions

fn get_partition_path(device: &str, num: u32) -> String {
    if device.contains("nvme") || device.contains("mmcblk") {
        format!("{}p{}", device, num)
    } else {
        format!("{}{}", device, num)
    }
}

fn get_device_size_gb(device: &str) -> Result<u64> {
    let output = Command::new("lsblk")
        .args(["-bdn", "-o", "SIZE", device])
        .output()
        .context("Failed to get device size")?;

    let size_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let size_bytes: u64 = size_str.parse().unwrap_or(0);

    Ok(size_bytes / 1_000_000_000)
}

fn is_usb_device(device: &str) -> Result<bool> {
    let output = Command::new("lsblk")
        .args(["-d", "-o", "TRAN", "-n", device])
        .output()
        .context("Failed to check device type")?;

    let transport = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(transport == "usb")
}

fn run_sudo(args: &[&str]) -> Result<()> {
    let status = Command::new("sudo")
        .args(args)
        .status()
        .context(format!("Failed to run: sudo {}", args.join(" ")))?;

    if !status.success() {
        anyhow::bail!("Command failed: sudo {}", args.join(" "));
    }
    Ok(())
}

fn write_file_as_root(path: &str, content: &str) -> Result<()> {
    // Use tee with sudo to write file as root
    let mut child = Command::new("sudo")
        .args(["tee", path])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .context("Failed to spawn tee")?;

    if let Some(stdin) = child.stdin.as_mut() {
        stdin.write_all(content.as_bytes())?;
    }

    let status = child.wait()?;
    if !status.success() {
        anyhow::bail!("Failed to write {}", path);
    }

    Ok(())
}

#[allow(dead_code)]
fn running_as_root() -> bool {
    unsafe { libc::geteuid() == 0 }
}
