//! Cloud CLI - Infrastructure management tool
//!
//! A Rust CLI for managing cloud infrastructure, including:
//! - Environment setup (sandbox, apps, configs)
//! - Cloud connectivity (VPN, SSH, mounts)
//! - System status (health, topology, endpoints)
//! - Data export (JSON, Markdown)

use anyhow::Result;
use clap::Parser;

mod cli;
mod config;
mod connect;
mod export;
mod setup;
mod status;

use cli::{Cli, Commands};

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Set verbosity
    if cli.verbose {
        std::env::set_var("RUST_LOG", "debug");
    }

    // Load configuration
    let cfg = config::Config::load(cli.config.as_deref())?;

    // Route to appropriate command handler
    match cli.command {
        Commands::Setup(cmd) => setup::handle(cmd, &cfg).await?,
        Commands::Connect(cmd) => connect::handle(cmd, &cfg).await?,
        Commands::Status(cmd) => status::handle(cmd, &cfg).await?,
        Commands::Export(cmd) => export::handle(cmd, &cfg).await?,
        Commands::Completions { shell } => cli::generate_completions(shell),
    }

    Ok(())
}
