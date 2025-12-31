//! Export module - JSON and Markdown export functionality

use crate::cli::ExportCommand;
use crate::config::Config;
use anyhow::Result;

/// Handle export commands
pub async fn handle(cmd: ExportCommand, _cfg: &Config) -> Result<()> {
    println!("Export module not yet implemented");
    println!("Command: {:?}", cmd.command);
    Ok(())
}
