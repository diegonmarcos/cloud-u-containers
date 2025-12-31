//! Mount management (SSHFS)

use crate::cli::MountAction;
use crate::config::{Config, Vm};
use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::path::Path;
use std::process::Command;

/// Handle mount subcommands
pub async fn handle_mount(action: MountAction, cfg: &Config) -> Result<()> {
    match action {
        MountAction::Up { vm, public } => {
            if let Some(alias) = vm {
                mount_vm_by_alias(cfg, &alias, public).await
            } else {
                mount_all(cfg, public).await
            }
        }
        MountAction::Down { vm } => {
            if let Some(alias) = vm {
                unmount_vm_by_alias(cfg, &alias).await
            } else {
                unmount_all(cfg).await
            }
        }
        MountAction::Status => mount_status(cfg).await,
    }
}

/// Mount all VMs
pub async fn mount_all(cfg: &Config, force_public: bool) -> Result<()> {
    println!("{}", "Mounting all VMs...".cyan());

    let vpn_connected = if force_public {
        false
    } else {
        check_vpn_connected(cfg).await
    };

    for vm in cfg.all_vms() {
        if let Err(e) = mount_vm(cfg, vm, vpn_connected).await {
            eprintln!("{} {}: {}", "Failed to mount".red(), vm.alias, e);
        }
    }

    Ok(())
}

/// Mount a specific VM by alias
async fn mount_vm_by_alias(cfg: &Config, alias: &str, force_public: bool) -> Result<()> {
    let vm = cfg
        .get_vm(alias)
        .with_context(|| format!("Unknown VM: {}", alias))?;

    let vpn_connected = if force_public {
        false
    } else {
        check_vpn_connected(cfg).await
    };

    mount_vm(cfg, vm, vpn_connected).await
}

/// Mount a single VM
async fn mount_vm(cfg: &Config, vm: &Vm, vpn_connected: bool) -> Result<()> {
    let mount_point = vm.mount_point(&cfg.mount.base_path);
    let ip = vm.preferred_ip(vpn_connected);

    // Create mount point if needed
    crate::config::ensure_dir(&mount_point)?;

    // Check if already mounted
    if is_mounted(&mount_point)? {
        println!("{} {} already mounted", "Skipping:".yellow(), vm.alias);
        return Ok(());
    }

    println!("{} {} at {}", "Mounting:".cyan(), vm.alias, mount_point.display());

    let ssh_key = crate::config::expand_tilde(&vm.ssh_key);
    let remote_path = format!("{}@{}:{}", vm.ssh_user, ip, vm.remote_path.display());

    let alive_interval = cfg.mount.server_alive_interval.to_string();

    let status = Command::new("sshfs")
        .args([
            "-o", &format!("IdentityFile={}", ssh_key.display()),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "reconnect",
            "-o", &format!("ServerAliveInterval={}", alive_interval),
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            &remote_path,
            &mount_point.to_string_lossy(),
        ])
        .status()
        .context("Failed to execute sshfs")?;

    if status.success() {
        println!("{} {} mounted successfully", "Success:".green(), vm.alias);
        Ok(())
    } else {
        anyhow::bail!("Failed to mount {}", vm.alias)
    }
}

/// Unmount all VMs
pub async fn unmount_all(cfg: &Config) -> Result<()> {
    println!("{}", "Unmounting all VMs...".cyan());

    for vm in cfg.all_vms() {
        let mount_point = vm.mount_point(&cfg.mount.base_path);
        if is_mounted(&mount_point)? {
            if let Err(e) = unmount(&mount_point).await {
                eprintln!("{} {}: {}", "Failed to unmount".red(), vm.alias, e);
            } else {
                println!("{} {} unmounted", "Success:".green(), vm.alias);
            }
        }
    }

    Ok(())
}

/// Unmount a specific VM by alias
async fn unmount_vm_by_alias(cfg: &Config, alias: &str) -> Result<()> {
    let vm = cfg
        .get_vm(alias)
        .with_context(|| format!("Unknown VM: {}", alias))?;

    let mount_point = vm.mount_point(&cfg.mount.base_path);

    if !is_mounted(&mount_point)? {
        println!("{} {} not mounted", "Skipping:".yellow(), vm.alias);
        return Ok(());
    }

    unmount(&mount_point).await?;
    println!("{} {} unmounted", "Success:".green(), vm.alias);
    Ok(())
}

/// Unmount a specific path
async fn unmount(path: &Path) -> Result<()> {
    // Try normal unmount first
    let status = Command::new("fusermount")
        .args(["-u", &path.to_string_lossy()])
        .status()
        .context("Failed to execute fusermount")?;

    if status.success() {
        return Ok(());
    }

    // Try lazy unmount if normal fails
    let status = Command::new("fusermount")
        .args(["-uz", &path.to_string_lossy()])
        .status()
        .context("Failed to execute fusermount -uz")?;

    if status.success() {
        Ok(())
    } else {
        anyhow::bail!("Failed to unmount {}", path.display())
    }
}

/// Check if a path is mounted
pub fn is_mounted(path: &Path) -> Result<bool> {
    if !path.exists() {
        return Ok(false);
    }

    let output = Command::new("mountpoint")
        .args(["-q", &path.to_string_lossy()])
        .status()
        .context("Failed to check mount status")?;

    Ok(output.success())
}

/// Show mount status
async fn mount_status(cfg: &Config) -> Result<()> {
    use tabled::{Table, Tabled};

    #[derive(Tabled)]
    struct MountRow {
        #[tabled(rename = "VM")]
        vm: String,
        #[tabled(rename = "Mount Point")]
        mount_point: String,
        #[tabled(rename = "Status")]
        status: String,
    }

    let mut rows = Vec::new();

    for vm in cfg.all_vms() {
        let mount_point = vm.mount_point(&cfg.mount.base_path);
        let mounted = is_mounted(&mount_point)?;

        rows.push(MountRow {
            vm: vm.alias.clone(),
            mount_point: mount_point.to_string_lossy().to_string(),
            status: if mounted {
                "mounted".green().to_string()
            } else {
                "not mounted".dimmed().to_string()
            },
        });
    }

    println!("{}", "Mount Status".bold().underline());
    println!();
    println!("{}", Table::new(rows));

    Ok(())
}

/// Check if VPN is connected
async fn check_vpn_connected(cfg: &Config) -> bool {
    let output = Command::new("sudo")
        .args(["wg", "show", &cfg.vpn.interface])
        .output();

    match output {
        Ok(out) => out.status.success(),
        Err(_) => false,
    }
}
