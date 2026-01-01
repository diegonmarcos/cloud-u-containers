//! SSH connection management

use crate::cli::SshAction;
use crate::config::{Config, SshMethod, Vm};
use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::process::Command;

/// Handle SSH subcommands
pub async fn handle_ssh(action: SshAction, cfg: &Config) -> Result<()> {
    match action {
        SshAction::Connect { vm } => ssh_connect(cfg, &vm).await,
        SshAction::List => ssh_list(cfg).await,
    }
}

/// Connect to a VM via SSH
pub async fn ssh_connect(cfg: &Config, alias: &str) -> Result<()> {
    let vm = cfg
        .get_vm(alias)
        .with_context(|| format!("Unknown VM: {}", alias))?;

    println!("{} {} ({})", "Connecting to:".cyan(), vm.name, vm.alias);

    // Check if VPN is connected to use WG IP
    let vpn_connected = check_vpn_connected(cfg).await;
    let ip = vm.preferred_ip(vpn_connected);

    println!("Using IP: {} {}", ip, if vpn_connected { "(WireGuard)".dimmed() } else { "(Public)".dimmed() });

    // Execute SSH based on method
    match vm.ssh_method {
        SshMethod::Gcloud => ssh_via_gcloud(vm).await,
        SshMethod::Direct => ssh_direct(vm, ip).await,
    }
}

/// SSH via gcloud compute ssh
async fn ssh_via_gcloud(vm: &Vm) -> Result<()> {
    // Extract zone from VM name or use default
    let zone = "us-central1-a"; // Could be stored in VM config

    let status = Command::new("gcloud")
        .args(["compute", "ssh", "arch-1", "--zone", zone])
        .status()
        .context("Failed to execute gcloud compute ssh")?;

    if status.success() {
        Ok(())
    } else {
        anyhow::bail!("SSH connection failed")
    }
}

/// Direct SSH connection
async fn ssh_direct(vm: &Vm, ip: &str) -> Result<()> {
    let ssh_key = crate::config::expand_tilde(&vm.ssh_key);

    let status = Command::new("ssh")
        .args([
            "-i",
            &ssh_key.to_string_lossy(),
            "-o",
            "StrictHostKeyChecking=accept-new",
            &format!("{}@{}", vm.ssh_user, ip),
        ])
        .status()
        .context("Failed to execute ssh")?;

    if status.success() {
        Ok(())
    } else {
        anyhow::bail!("SSH connection failed")
    }
}

/// List available SSH targets
pub async fn ssh_list(cfg: &Config) -> Result<()> {
    use tabled::{Table, Tabled};

    #[derive(Tabled)]
    struct VmRow {
        #[tabled(rename = "Alias")]
        alias: String,
        #[tabled(rename = "Name")]
        name: String,
        #[tabled(rename = "Public IP")]
        public_ip: String,
        #[tabled(rename = "WG IP")]
        wg_ip: String,
        #[tabled(rename = "User")]
        user: String,
        #[tabled(rename = "Method")]
        method: String,
    }

    let rows: Vec<VmRow> = cfg
        .all_vms()
        .iter()
        .map(|vm| VmRow {
            alias: vm.alias.clone(),
            name: vm.name.clone(),
            public_ip: vm.public_ip.clone(),
            wg_ip: vm.wg_ip.clone().unwrap_or_else(|| "-".to_string()),
            user: vm.ssh_user.clone(),
            method: format!("{:?}", vm.ssh_method),
        })
        .collect();

    println!("{}", "Available SSH Targets".bold().underline());
    println!();
    println!("{}", Table::new(rows));
    println!();
    println!("Usage: {} {}", "cloud connect ssh to".dimmed(), "<alias>".cyan());

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
