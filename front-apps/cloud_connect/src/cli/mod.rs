//! CLI module - Command-line interface definitions

mod parser;

pub use parser::*;

use clap::CommandFactory;
use clap_complete::{generate, Shell};
use std::io;

/// Generate shell completions
pub fn generate_completions(shell: Shell) {
    let mut cmd = Cli::command();
    generate(shell, &mut cmd, "cloud", &mut io::stdout());
}
