//! VPN management (WireGuard)

use crate::cli::VpnAction;
use crate::config::Config;
use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::process::Command;

/// VPN status information
#[derive(Debug)]
pub struct VpnStatus {
    pub connected: bool,
    pub mode: String,
    pub interface: String,
    pub transfer: Option<Transfer>,
    pub latest_handshake: Option<String>,
}

#[derive(Debug)]
pub struct Transfer {
    pub rx: String,
    pub tx: String,
}

/// Handle VPN subcommands
pub async fn handle_vpn(action: VpnAction, cfg: &Config) -> Result<()> {
    match action {
        VpnAction::Up => vpn_up(cfg).await,
        VpnAction::Down => vpn_down(cfg).await,
        VpnAction::Status => vpn_status(cfg).await,
        VpnAction::Toggle => vpn_toggle(cfg).await,
        VpnAction::Split => vpn_set_mode(cfg, "split").await,
        VpnAction::Full => vpn_set_mode(cfg, "full").await,
        VpnAction::Setup => vpn_setup(cfg).await,
    }
}

/// Bring VPN up
pub async fn vpn_up(cfg: &Config) -> Result<()> {
    let interface = &cfg.vpn.interface;
    println!("{} {}", "Connecting VPN:".cyan(), interface);

    let output = Command::new("sudo")
        .args(["wg-quick", "up", interface])
        .output()
        .context("Failed to execute wg-quick up")?;

    if output.status.success() {
        println!("{}", "VPN connected successfully".green());
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("already exists") {
            println!("{}", "VPN already connected".yellow());
            Ok(())
        } else {
            anyhow::bail!("Failed to connect VPN: {}", stderr)
        }
    }
}

/// Bring VPN down
pub async fn vpn_down(cfg: &Config) -> Result<()> {
    let interface = &cfg.vpn.interface;
    println!("{} {}", "Disconnecting VPN:".cyan(), interface);

    let output = Command::new("sudo")
        .args(["wg-quick", "down", interface])
        .output()
        .context("Failed to execute wg-quick down")?;

    if output.status.success() {
        println!("{}", "VPN disconnected".green());
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("is not a WireGuard interface") {
            println!("{}", "VPN already disconnected".yellow());
            Ok(())
        } else {
            anyhow::bail!("Failed to disconnect VPN: {}", stderr)
        }
    }
}

/// Show VPN status
pub async fn vpn_status(cfg: &Config) -> Result<()> {
    let status = get_vpn_status(cfg).await?;

    println!("{}", "VPN Status".bold().underline());
    println!();

    if status.connected {
        println!("Status:    {}", "Connected".green());
        println!("Interface: {}", status.interface);
        println!("Mode:      {}", status.mode);

        if let Some(transfer) = &status.transfer {
            println!("Received:  {}", transfer.rx);
            println!("Sent:      {}", transfer.tx);
        }

        if let Some(handshake) = &status.latest_handshake {
            println!("Handshake: {}", handshake);
        }
    } else {
        println!("Status: {}", "Disconnected".red());
    }

    Ok(())
}

/// Get VPN status
pub async fn get_vpn_status(cfg: &Config) -> Result<VpnStatus> {
    let interface = &cfg.vpn.interface;

    let output = Command::new("sudo")
        .args(["wg", "show", interface])
        .output()
        .context("Failed to execute wg show")?;

    if !output.status.success() {
        return Ok(VpnStatus {
            connected: false,
            mode: "none".to_string(),
            interface: interface.clone(),
            transfer: None,
            latest_handshake: None,
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);

    // Parse transfer stats
    let transfer = parse_transfer(&stdout);

    // Parse handshake
    let latest_handshake = stdout
        .lines()
        .find(|l| l.contains("latest handshake:"))
        .map(|l| l.split(':').skip(1).collect::<Vec<_>>().join(":").trim().to_string());

    // Determine mode from AllowedIPs
    let mode = if stdout.contains("0.0.0.0/0") {
        "full"
    } else {
        "split"
    };

    Ok(VpnStatus {
        connected: true,
        mode: mode.to_string(),
        interface: interface.clone(),
        transfer,
        latest_handshake,
    })
}

fn parse_transfer(output: &str) -> Option<Transfer> {
    let line = output.lines().find(|l| l.contains("transfer:"))?;
    let parts: Vec<&str> = line.split_whitespace().collect();

    // Format: "transfer: X received, Y sent"
    let rx_idx = parts.iter().position(|&s| s == "transfer:")?;
    let rx = parts.get(rx_idx + 1)?.to_string();
    let tx = parts.get(rx_idx + 3)?.to_string();

    Some(Transfer { rx, tx })
}

/// Toggle VPN tunnel mode
async fn vpn_toggle(cfg: &Config) -> Result<()> {
    let status = get_vpn_status(cfg).await?;

    if !status.connected {
        println!("{}", "VPN not connected".yellow());
        return Ok(());
    }

    let new_mode = if status.mode == "split" { "full" } else { "split" };
    vpn_set_mode(cfg, new_mode).await
}

/// Set VPN tunnel mode
async fn vpn_set_mode(cfg: &Config, mode: &str) -> Result<()> {
    println!("{} {}", "Setting VPN mode:".cyan(), mode);

    // This would require modifying the WireGuard config and restarting
    // For now, just inform the user
    println!(
        "{}",
        "Note: Mode change requires config modification and VPN restart".yellow()
    );
    println!("Edit {} and change AllowedIPs:", cfg.vpn.config_path.display());
    println!("  Split: AllowedIPs = 10.0.0.0/24");
    println!("  Full:  AllowedIPs = 0.0.0.0/0, ::/0");

    Ok(())
}

/// Setup VPN configuration
async fn vpn_setup(cfg: &Config) -> Result<()> {
    println!("{}", "VPN Setup".bold().underline());
    println!();

    // Check wg-quick installed
    let wg_installed = which::which("wg").is_ok();
    println!(
        "WireGuard tools: {}",
        if wg_installed { "installed".green().to_string() } else { "missing".red().to_string() }
    );

    // Check config exists
    let config_exists = cfg.vpn.config_path.exists();
    println!(
        "Config file:     {}",
        if config_exists {
            format!("{} ({})", "exists".green(), cfg.vpn.config_path.display())
        } else {
            format!("{} ({})", "missing".red(), cfg.vpn.config_path.display())
        }
    );

    if !wg_installed {
        println!();
        println!("Install WireGuard tools:");
        println!("  Arch:   sudo pacman -S wireguard-tools");
        println!("  Ubuntu: sudo apt install wireguard-tools");
    }

    if !config_exists {
        println!();
        println!("Create config at {} with your WireGuard configuration", cfg.vpn.config_path.display());
    }

    Ok(())
}
