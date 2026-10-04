//! Setup module - Sandbox, apps, and configs management

mod apps;
mod sandbox;
mod usb;
mod vpn;

use crate::cli::{SetupCommand, SetupSubcommand, SandboxAction, AppsAction, ConfigsAction, UsbAction};
use crate::config::Config;
use anyhow::Result;
use owo_colors::OwoColorize;

/// Handle setup commands
pub async fn handle(cmd: SetupCommand, cfg: &Config) -> Result<()> {
    match cmd.command {
        SetupSubcommand::Sandbox { action } => handle_sandbox(action, cfg).await,
        SetupSubcommand::Apps { action } => handle_apps(action, cfg).await,
        SetupSubcommand::Configs { action } => handle_configs(action, cfg).await,
        SetupSubcommand::Usb { action } => handle_usb(action).await,
        SetupSubcommand::All { yes } => handle_all(cfg, yes).await,
        SetupSubcommand::Check => handle_check(cfg).await,
    }
}

/// Handle sandbox subcommands
async fn handle_sandbox(action: SandboxAction, cfg: &Config) -> Result<()> {
    match action {
        SandboxAction::Create { name, sandbox_type: _ } => {
            sandbox::create_sandbox(cfg, &name).await
        }
        SandboxAction::Enter { name } => {
            sandbox::enter_sandbox(cfg, &name).await
        }
        SandboxAction::List => {
            sandbox::list_sandboxes(cfg).await
        }
        SandboxAction::Destroy { name, force } => {
            sandbox::destroy_sandbox(cfg, &name, force).await
        }
    }
}

/// Handle apps subcommands
async fn handle_apps(action: AppsAction, cfg: &Config) -> Result<()> {
    match action {
        AppsAction::Install { app } => {
            if let Some(app_name) = app {
                apps::install_app(cfg, &app_name, None).await
            } else {
                apps::install_all(cfg, None).await
            }
        }
        AppsAction::List => {
            println!("{}", "Available apps".bold().underline());
            println!();
            println!("Terminal: {:?}", cfg.apps.apps.terminal);
            println!("Browser:  {:?}", cfg.apps.apps.browser);
            println!("Notes:    {:?}", cfg.apps.apps.notes);
            println!("IDE:      {:?}", cfg.apps.apps.ide);
            println!("Utils:    {:?}", cfg.apps.apps.utils);
            Ok(())
        }
        AppsAction::Check => {
            apps::check_apps(cfg, None).await
        }
    }
}

/// Handle configs subcommands
async fn handle_configs(action: ConfigsAction, cfg: &Config) -> Result<()> {
    match action {
        ConfigsAction::Apply { target } => {
            println!("{}", "Applying configs".bold().underline());
            println!();
            println!("Source: {}", cfg.configs.source.display());
            if let Some(t) = target {
                println!("Target: {}", t.cyan());
            } else {
                println!("Targets: {:?}", cfg.configs.targets);
            }
            println!();
            println!("{}", "Not yet implemented - coming soon".yellow());
            Ok(())
        }
        ConfigsAction::Pull => {
            println!("{}", "Pulling configs from source...".cyan());
            println!("{}", "Not yet implemented".yellow());
            Ok(())
        }
        ConfigsAction::Diff => {
            println!("{}", "Showing config differences...".cyan());
            println!("{}", "Not yet implemented".yellow());
            Ok(())
        }
        ConfigsAction::Backup => {
            println!("{}", "Backing up current configs...".cyan());
            println!("{}", "Not yet implemented".yellow());
            Ok(())
        }
    }
}

/// Handle USB subcommands
async fn handle_usb(action: UsbAction) -> Result<()> {
    match action {
        UsbAction::Create { device, iso, persist, persist_size, yes } => {
            usb::create_bootable_usb(&device, iso, persist, persist_size, yes).await
        }
        UsbAction::List => {
            usb::list_usb_devices().await
        }
        UsbAction::Download { output } => {
            usb::download_iso(output).await?;
            Ok(())
        }
        UsbAction::Verify { iso } => {
            usb::verify_iso(&iso).await?;
            Ok(())
        }
    }
}

/// Run all setup steps
async fn handle_all(cfg: &Config, _yes: bool) -> Result<()> {
    println!("{}", "Full Setup".bold().underline());
    println!();
    println!("This will:");
    println!("  1. Create a sandbox container");
    println!("  2. Install all configured apps");
    println!("  3. Apply all configs");
    println!();
    println!("{}", "Not yet implemented - coming soon".yellow());
    Ok(())
}

/// Run all checks
async fn handle_check(cfg: &Config) -> Result<()> {
    println!("{}", "Setup Checks".bold().underline());
    println!();

    // Check Docker
    let docker_ok = std::process::Command::new("docker")
        .args(["--version"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    println!(
        "Docker: {}",
        if docker_ok { "installed".green().to_string() } else { "missing".red().to_string() }
    );

    // Check config source
    let config_source_ok = cfg.configs.source.exists();
    println!(
        "Config source: {}",
        if config_source_ok {
            format!("{} ({})", "exists".green(), cfg.configs.source.display())
        } else {
            format!("{} ({})", "missing".red(), cfg.configs.source.display())
        }
    );

    // Check sandbox data dir
    let sandbox_dir_ok = cfg.sandbox.data_dir.exists();
    println!(
        "Sandbox data: {}",
        if sandbox_dir_ok {
            format!("{} ({})", "exists".green(), cfg.sandbox.data_dir.display())
        } else {
            format!("{} (will be created)", "missing".yellow())
        }
    );

    Ok(())
}
