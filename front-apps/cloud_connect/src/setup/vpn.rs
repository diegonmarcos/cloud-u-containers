//! VPN module - Auto-setup WireGuard in sandbox containers

use crate::config::Config;
use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::process::Command;

/// Setup VPN in a sandbox container
pub async fn setup_vpn_in_container(cfg: &Config, container_name: &str) -> Result<()> {
    let full_name = if container_name.starts_with("cloud-sandbox-") {
        container_name.to_string()
    } else {
        format!("cloud-sandbox-{}", container_name)
    };

    println!("{}", "Setting up VPN in container...".cyan());
    println!("  Container: {}", full_name);

    // Check if container is running
    if !container_running(&full_name)? {
        anyhow::bail!("Container '{}' is not running", full_name);
    }

    // Install WireGuard tools in container
    install_wireguard_tools(&full_name).await?;

    // Copy WireGuard config if available
    if let Some(wg_config) = find_wireguard_config(cfg) {
        copy_wireguard_config(&full_name, &wg_config).await?;
        enable_wireguard(&full_name).await?;
    } else {
        println!("{} No WireGuard config found", "Warning:".yellow());
        println!("  Expected at: ~/.config/wireguard/*.conf or /etc/wireguard/*.conf");
        println!("  You can manually copy config to container and run:");
        println!("    docker exec {} wg-quick up <interface>", full_name);
    }

    Ok(())
}

/// Install WireGuard tools inside container
async fn install_wireguard_tools(container: &str) -> Result<()> {
    println!("{}", "Installing WireGuard tools...".dimmed());

    // Update and install wireguard-tools
    let status = Command::new("docker")
        .args([
            "exec", container,
            "pacman", "-S", "--noconfirm", "--needed",
            "wireguard-tools"
        ])
        .status()
        .context("Failed to install WireGuard tools")?;

    if status.success() {
        println!("{} WireGuard tools installed", "Success:".green());
        Ok(())
    } else {
        anyhow::bail!("Failed to install WireGuard tools")
    }
}

/// Find WireGuard config file on host
fn find_wireguard_config(cfg: &Config) -> Option<String> {
    // Check configured VPN config path first
    let vpn_config = &cfg.vpn.config_path;
    if vpn_config.exists() {
        return Some(vpn_config.to_string_lossy().to_string());
    }

    // Check common locations
    let home = std::env::var("HOME").unwrap_or_default();
    let locations = [
        format!("{}/.config/wireguard/wg0.conf", home),
        format!("{}/.config/wireguard/mullvad.conf", home),
        "/etc/wireguard/wg0.conf".to_string(),
    ];

    for loc in locations {
        if std::path::Path::new(&loc).exists() {
            return Some(loc);
        }
    }

    None
}

/// Copy WireGuard config to container
async fn copy_wireguard_config(container: &str, config_path: &str) -> Result<()> {
    println!("{} Copying WireGuard config...", "Info:".cyan());
    println!("  From: {}", config_path);

    // Create /etc/wireguard in container
    let _ = Command::new("docker")
        .args(["exec", container, "mkdir", "-p", "/etc/wireguard"])
        .status();

    // Copy config file
    let dest = format!("{}:/etc/wireguard/wg0.conf", container);
    let status = Command::new("docker")
        .args(["cp", config_path, &dest])
        .status()
        .context("Failed to copy WireGuard config")?;

    if status.success() {
        // Set permissions
        let _ = Command::new("docker")
            .args(["exec", container, "chmod", "600", "/etc/wireguard/wg0.conf"])
            .status();

        println!("{} Config copied to container", "Success:".green());
        Ok(())
    } else {
        anyhow::bail!("Failed to copy WireGuard config")
    }
}

/// Enable WireGuard interface in container
async fn enable_wireguard(container: &str) -> Result<()> {
    println!("{} Enabling WireGuard interface...", "Info:".cyan());

    let status = Command::new("docker")
        .args(["exec", container, "wg-quick", "up", "wg0"])
        .status()
        .context("Failed to enable WireGuard")?;

    if status.success() {
        println!("{} WireGuard VPN connected", "Success:".green());

        // Show connection info
        let output = Command::new("docker")
            .args(["exec", container, "wg", "show"])
            .output()?;

        if output.status.success() {
            println!();
            println!("{}", "Connection details:".bold());
            println!("{}", String::from_utf8_lossy(&output.stdout));
        }

        Ok(())
    } else {
        println!("{} WireGuard activation failed", "Warning:".yellow());
        println!("  Try manually: docker exec {} wg-quick up wg0", container);
        Ok(())
    }
}

/// Check VPN status in container
pub async fn check_vpn_status(container: &str) -> Result<()> {
    let full_name = if container.starts_with("cloud-sandbox-") {
        container.to_string()
    } else {
        format!("cloud-sandbox-{}", container)
    };

    println!("{}", "VPN Status".bold().underline());
    println!();

    // Check if wg is installed
    let wg_check = Command::new("docker")
        .args(["exec", &full_name, "which", "wg"])
        .output()?;

    if !wg_check.status.success() {
        println!("WireGuard: {}", "not installed".red().to_string());
        return Ok(());
    }

    // Check interface status
    let output = Command::new("docker")
        .args(["exec", &full_name, "wg", "show"])
        .output()?;

    if output.status.success() && !output.stdout.is_empty() {
        println!("WireGuard: {}", "connected".green().to_string());
        println!();
        println!("{}", String::from_utf8_lossy(&output.stdout));
    } else {
        println!("WireGuard: {}", "not connected".yellow().to_string());
    }

    Ok(())
}

/// Disconnect VPN in container
pub async fn disconnect_vpn(container: &str) -> Result<()> {
    let full_name = if container.starts_with("cloud-sandbox-") {
        container.to_string()
    } else {
        format!("cloud-sandbox-{}", container)
    };

    println!("{} Disconnecting VPN...", "Info:".cyan());

    let status = Command::new("docker")
        .args(["exec", &full_name, "wg-quick", "down", "wg0"])
        .status()
        .context("Failed to disconnect VPN")?;

    if status.success() {
        println!("{} VPN disconnected", "Success:".green());
    } else {
        println!("{} VPN may already be disconnected", "Info:".cyan());
    }

    Ok(())
}

// Helper function
fn container_running(name: &str) -> Result<bool> {
    let output = Command::new("docker")
        .args(["ps", "--filter", &format!("name=^{}$", name), "-q"])
        .output()
        .context("Failed to check container status")?;

    Ok(!output.stdout.is_empty())
}
