//! CLI parser definitions using clap derive

use clap::{Parser, Subcommand, ValueEnum};
use clap_complete::Shell;
use std::path::PathBuf;

/// Cloud CLI - Infrastructure management tool
#[derive(Parser, Debug)]
#[command(name = "cloud")]
#[command(author, version, about, long_about = None)]
#[command(propagate_version = true)]
pub struct Cli {
    /// Enable verbose output
    #[arg(short, long, global = true)]
    pub verbose: bool,

    /// Quiet mode - minimal output
    #[arg(short, long, global = true)]
    pub quiet: bool,

    /// Config file path
    #[arg(short, long, global = true, env = "CLOUD_CONFIG")]
    pub config: Option<PathBuf>,

    /// Output as JSON (for scripting)
    #[arg(long, global = true)]
    pub json: bool,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// System setup (sandbox, apps, configs)
    Setup(SetupCommand),

    /// Cloud connectivity (VPN, SSH, mount)
    Connect(ConnectCommand),

    /// System status (health, topology, endpoints)
    Status(StatusCommand),

    /// Export data (JSON, Markdown)
    Export(ExportCommand),

    /// Generate shell completions
    Completions {
        /// Shell to generate completions for
        #[arg(value_enum)]
        shell: Shell,
    },
}

// ============================================================================
// Setup Commands
// ============================================================================

#[derive(Parser, Debug)]
pub struct SetupCommand {
    #[command(subcommand)]
    pub command: SetupSubcommand,
}

#[derive(Subcommand, Debug)]
pub enum SetupSubcommand {
    /// Sandbox environment management
    Sandbox {
        #[command(subcommand)]
        action: SandboxAction,
    },

    /// Application installation
    Apps {
        #[command(subcommand)]
        action: AppsAction,
    },

    /// Configuration deployment
    Configs {
        #[command(subcommand)]
        action: ConfigsAction,
    },

    /// USB bootable image management
    Usb {
        #[command(subcommand)]
        action: UsbAction,
    },

    /// Run complete setup
    All {
        /// Skip confirmation prompts
        #[arg(short = 'y', long)]
        yes: bool,
    },

    /// Run all setup checks
    Check,
}

#[derive(Subcommand, Debug)]
pub enum SandboxAction {
    /// Create a new sandbox
    Create {
        /// Sandbox name
        name: String,
        /// Sandbox type
        #[arg(short, long, value_enum, default_value = "docker")]
        sandbox_type: SandboxType,
    },
    /// List existing sandboxes
    List,
    /// Enter a sandbox
    Enter { name: String },
    /// Destroy a sandbox
    Destroy {
        name: String,
        /// Force removal
        #[arg(short, long)]
        force: bool,
    },
}

#[derive(ValueEnum, Clone, Debug)]
pub enum SandboxType {
    Docker,
    Systemd,
    Flatpak,
}

#[derive(Subcommand, Debug)]
pub enum AppsAction {
    /// Install applications
    Install {
        /// Specific app to install (omit for all)
        app: Option<String>,
    },
    /// List available apps
    List,
    /// Check installed status
    Check,
}

#[derive(Subcommand, Debug)]
pub enum ConfigsAction {
    /// Apply configurations
    Apply {
        /// Target: linux, browser, ide, git (omit for all)
        target: Option<String>,
    },
    /// Pull latest configs from source
    Pull,
    /// Show config differences
    Diff,
    /// Backup current configs
    Backup,
}

#[derive(Subcommand, Debug)]
pub enum UsbAction {
    /// Create bootable Arch Linux USB
    Create {
        /// Target USB device (e.g., /dev/sdb)
        device: String,
        /// Custom ISO path (downloads latest if omitted)
        #[arg(short, long)]
        iso: Option<PathBuf>,
        /// Add persistence partition
        #[arg(short, long)]
        persist: bool,
        /// Persistence partition size in GB
        #[arg(long, default_value = "4")]
        persist_size: u32,
        /// Skip confirmation
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// List available USB devices
    List,
    /// Download latest Arch ISO
    Download {
        /// Output directory
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Verify ISO checksum
    Verify {
        /// Path to ISO file
        iso: PathBuf,
    },
}

// ============================================================================
// Connect Commands
// ============================================================================

#[derive(Parser, Debug)]
pub struct ConnectCommand {
    #[command(subcommand)]
    pub command: ConnectSubcommand,
}

#[derive(Subcommand, Debug)]
pub enum ConnectSubcommand {
    /// VPN management
    Vpn {
        #[command(subcommand)]
        action: VpnAction,
    },

    /// SSH connections
    Ssh {
        #[command(subcommand)]
        action: SshAction,
    },

    /// Remote mount management
    Mount {
        #[command(subcommand)]
        action: MountAction,
    },

    /// Connect VPN and mount all
    Up,

    /// Unmount all and disconnect VPN
    Down,

    /// Show connection status
    Status,
}

#[derive(Subcommand, Debug)]
pub enum VpnAction {
    /// Connect VPN
    Up,
    /// Disconnect VPN
    Down,
    /// Show VPN status
    Status,
    /// Toggle split/full tunnel
    Toggle,
    /// Split tunnel mode (only cloud traffic)
    Split,
    /// Full tunnel mode (all traffic)
    Full,
    /// Setup VPN configuration
    Setup,
}

#[derive(Subcommand, Debug)]
pub enum SshAction {
    /// Connect to a VM
    #[command(name = "to")]
    Connect {
        /// VM alias (gcp, dev, web, services)
        vm: String,
    },
    /// List available VMs
    List,
}

#[derive(Subcommand, Debug)]
pub enum MountAction {
    /// Mount all or specific VM
    Up {
        /// VM alias (omit for all)
        vm: Option<String>,
        /// Force public IP
        #[arg(long)]
        public: bool,
    },
    /// Unmount all or specific VM
    Down {
        /// VM alias (omit for all)
        vm: Option<String>,
    },
    /// Show mount status
    Status,
}

// ============================================================================
// Status Commands
// ============================================================================

#[derive(Parser, Debug)]
pub struct StatusCommand {
    #[command(subcommand)]
    pub command: StatusSubcommand,
}

#[derive(Subcommand, Debug)]
pub enum StatusSubcommand {
    /// Health checks
    Health {
        /// Category: vm, service, docker, ssl (omit for all)
        category: Option<String>,
        /// Live monitoring mode
        #[arg(short, long)]
        watch: bool,
        /// Refresh interval in seconds
        #[arg(short, long, default_value = "5")]
        interval: u64,
    },

    /// Network topology
    Topology {
        /// Output format
        #[arg(short, long, value_enum, default_value = "ascii")]
        format: TopologyFormat,
    },

    /// Endpoint registry
    Endpoints {
        /// Service name (omit for all)
        service: Option<String>,
        /// Verify endpoints are responding
        #[arg(short, long)]
        check: bool,
    },

    /// VM status
    Vms {
        /// VM alias (omit for all)
        vm: Option<String>,
    },
}

#[derive(ValueEnum, Clone, Debug)]
pub enum TopologyFormat {
    Ascii,
    Json,
    Svg,
    Mermaid,
}

// ============================================================================
// Export Commands
// ============================================================================

#[derive(Parser, Debug)]
pub struct ExportCommand {
    #[command(subcommand)]
    pub command: ExportSubcommand,
}

#[derive(Subcommand, Debug)]
pub enum ExportSubcommand {
    /// Export everything
    All {
        /// Output directory
        #[arg(short, long)]
        output: Option<PathBuf>,
    },

    /// Export topology
    Topology {
        #[arg(short, long, value_enum, default_value = "both")]
        format: ExportFormat,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },

    /// Export health report
    Health {
        #[arg(short, long, value_enum, default_value = "both")]
        format: ExportFormat,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },

    /// Export endpoints
    Endpoints {
        #[arg(short, long, value_enum, default_value = "both")]
        format: ExportFormat,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },

    /// Export full inventory
    Inventory {
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
}

#[derive(ValueEnum, Clone, Debug)]
pub enum ExportFormat {
    Json,
    Md,
    Both,
}
