//! Connect module - VPN, SSH, and mount management

mod mount;
mod ssh;
mod vpn;

pub use mount::*;
pub use ssh::*;
pub use vpn::*;

use crate::cli::ConnectSubcommand;
use crate::config::Config;
use anyhow::Result;
use owo_colors::OwoColorize;

/// Handle connect commands
pub async fn handle(cmd: crate::cli::ConnectCommand, cfg: &Config) -> Result<()> {
    match cmd.command {
        ConnectSubcommand::Vpn { action } => vpn::handle_vpn(action, cfg).await,
        ConnectSubcommand::Ssh { action } => ssh::handle_ssh(action, cfg).await,
        ConnectSubcommand::Mount { action } => mount::handle_mount(action, cfg).await,
        ConnectSubcommand::Up => {
            println!("{}", "Connecting VPN and mounting drives...".cyan());
            vpn::vpn_up(cfg).await?;
            mount::mount_all(cfg, false).await?;
            Ok(())
        }
        ConnectSubcommand::Down => {
            println!("{}", "Unmounting drives and disconnecting VPN...".cyan());
            mount::unmount_all(cfg).await?;
            vpn::vpn_down(cfg).await?;
            Ok(())
        }
        ConnectSubcommand::Status => {
            print_connection_status(cfg).await
        }
    }
}

/// Print full connection status
async fn print_connection_status(cfg: &Config) -> Result<()> {
    println!("{}", "Connection Status".bold().underline());
    println!();

    // VPN status
    let vpn_status = vpn::get_vpn_status(cfg).await?;
    println!("VPN: {}", if vpn_status.connected {
        format!("{} ({})", "Connected".green(), vpn_status.mode)
    } else {
        "Disconnected".red().to_string()
    });

    if vpn_status.connected {
        if let Some(transfer) = vpn_status.transfer {
            println!("  Transfer: {} rx / {} tx", transfer.rx, transfer.tx);
        }
    }
    println!();

    // Mount status
    println!("Mounts:");
    for vm in cfg.all_vms() {
        let mount_point = vm.mount_point(&cfg.mount.base_path);
        let is_mounted = mount::is_mounted(&mount_point)?;
        let status = if is_mounted {
            "mounted".green().to_string()
        } else {
            "not mounted".dimmed().to_string()
        };
        println!("  {} ({}): {}", vm.name, vm.alias, status);
    }

    Ok(())
}
