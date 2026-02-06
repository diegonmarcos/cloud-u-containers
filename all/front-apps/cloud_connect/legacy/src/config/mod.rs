//! Configuration module - Paths, settings, VM definitions

mod paths;
mod vms;

pub use paths::*;
pub use vms::*;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Main configuration struct
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub general: GeneralConfig,
    pub vpn: VpnConfig,
    pub mount: MountConfig,
    pub sandbox: SandboxConfig,
    pub apps: AppsConfig,
    pub configs: ConfigsConfig,
    pub vms: Vec<Vm>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneralConfig {
    #[serde(default)]
    pub verbose: bool,
    #[serde(default = "default_export_dir")]
    pub export_dir: PathBuf,
}

fn default_export_dir() -> PathBuf {
    dirs::document_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join("exports/cloud")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VpnConfig {
    #[serde(default = "default_wg_interface")]
    pub interface: String,
    #[serde(default)]
    pub default_mode: VpnMode,
    #[serde(default = "default_wg_config")]
    pub config_path: PathBuf,
}

fn default_wg_interface() -> String {
    "wg0".to_string()
}

fn default_wg_config() -> PathBuf {
    PathBuf::from("/etc/wireguard/wg0.conf")
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VpnMode {
    #[default]
    Split,
    Full,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MountConfig {
    #[serde(default = "default_mount_base")]
    pub base_path: PathBuf,
    #[serde(default = "default_true")]
    pub reconnect: bool,
    #[serde(default = "default_alive_interval")]
    pub server_alive_interval: u32,
}

fn default_mount_base() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join("mnt/cloud")
}

fn default_alive_interval() -> u32 {
    15
}

fn default_true() -> bool {
    true
}

/// Sandbox configuration - Docker-based portable dev environment
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SandboxConfig {
    /// Docker image to use as base
    #[serde(default = "default_sandbox_image")]
    pub base_image: String,

    /// Name prefix for sandbox containers
    #[serde(default = "default_sandbox_prefix")]
    pub container_prefix: String,

    /// Directory to store sandbox data
    #[serde(default = "default_sandbox_data")]
    pub data_dir: PathBuf,

    /// Volumes to mount inside container
    #[serde(default)]
    pub volumes: Vec<VolumeMount>,

    /// Environment variables to set
    #[serde(default)]
    pub env_vars: Vec<EnvVar>,

    /// Whether to auto-connect VPN inside container
    #[serde(default = "default_true")]
    pub auto_vpn: bool,

    /// Whether to auto-mount drives inside container
    #[serde(default = "default_true")]
    pub auto_mount: bool,
}

fn default_sandbox_image() -> String {
    "archlinux:latest".to_string()
}

fn default_sandbox_prefix() -> String {
    "cloud-sandbox".to_string()
}

fn default_sandbox_data() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("~/.local/share"))
        .join("cloud/sandbox")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolumeMount {
    pub host_path: PathBuf,
    pub container_path: PathBuf,
    #[serde(default)]
    pub readonly: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppsConfig {
    #[serde(default = "default_pkg_manager")]
    pub package_manager: String,
    #[serde(default = "default_aur_helper")]
    pub aur_helper: String,
    #[serde(default)]
    pub apps: AppsList,
}

fn default_pkg_manager() -> String {
    "pacman".to_string()
}

fn default_aur_helper() -> String {
    "yay".to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AppsList {
    #[serde(default)]
    pub terminal: Vec<String>,
    #[serde(default)]
    pub browser: Vec<String>,
    #[serde(default)]
    pub notes: Vec<String>,
    #[serde(default)]
    pub ide: Vec<String>,
    #[serde(default)]
    pub utils: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigsConfig {
    #[serde(default = "default_configs_source")]
    pub source: PathBuf,
    #[serde(default = "default_targets")]
    pub targets: Vec<String>,
}

fn default_configs_source() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join("Documents/Git/LOCAL_KEYS/configs")
}

fn default_targets() -> Vec<String> {
    vec![
        "linux".to_string(),
        "browser".to_string(),
        "ide".to_string(),
        "git".to_string(),
    ]
}

impl Config {
    /// Load configuration from file or create default
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let config_path = path
            .map(PathBuf::from)
            .unwrap_or_else(Self::default_config_path);

        if config_path.exists() {
            let content = std::fs::read_to_string(&config_path)
                .with_context(|| format!("Failed to read config: {:?}", config_path))?;
            toml::from_str(&content)
                .with_context(|| format!("Failed to parse config: {:?}", config_path))
        } else {
            Ok(Self::default())
        }
    }

    /// Save configuration to file
    pub fn save(&self, path: Option<&Path>) -> Result<()> {
        let config_path = path
            .map(PathBuf::from)
            .unwrap_or_else(Self::default_config_path);

        // Ensure parent directory exists
        if let Some(parent) = config_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let content = toml::to_string_pretty(self)?;
        std::fs::write(&config_path, content)?;
        Ok(())
    }

    /// Default config file path
    pub fn default_config_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("~/.config"))
            .join("cloud/config.toml")
    }

    /// Get VM by alias
    pub fn get_vm(&self, alias: &str) -> Option<&Vm> {
        self.vms.iter().find(|vm| vm.alias == alias)
    }

    /// Get all VMs
    pub fn all_vms(&self) -> &[Vm] {
        &self.vms
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            general: GeneralConfig {
                verbose: false,
                export_dir: default_export_dir(),
            },
            vpn: VpnConfig {
                interface: default_wg_interface(),
                default_mode: VpnMode::Split,
                config_path: default_wg_config(),
            },
            mount: MountConfig {
                base_path: default_mount_base(),
                reconnect: true,
                server_alive_interval: 15,
            },
            sandbox: SandboxConfig {
                base_image: default_sandbox_image(),
                container_prefix: default_sandbox_prefix(),
                data_dir: default_sandbox_data(),
                volumes: vec![],
                env_vars: vec![],
                auto_vpn: true,
                auto_mount: true,
            },
            apps: AppsConfig {
                package_manager: default_pkg_manager(),
                aur_helper: default_aur_helper(),
                apps: AppsList {
                    terminal: vec!["fish".to_string(), "kitty".to_string()],
                    browser: vec!["brave-bin".to_string()],
                    notes: vec!["obsidian".to_string()],
                    ide: vec!["code".to_string()],
                    utils: vec!["htop".to_string(), "ripgrep".to_string(), "fd".to_string()],
                },
            },
            configs: ConfigsConfig {
                source: default_configs_source(),
                targets: default_targets(),
            },
            vms: default_vms(),
        }
    }
}

/// Default VM definitions
fn default_vms() -> Vec<Vm> {
    vec![
        Vm {
            name: "GCP Hub".to_string(),
            alias: "gcp".to_string(),
            provider: Provider::GCP,
            public_ip: "34.55.55.234".to_string(),
            wg_ip: Some("10.0.0.1".to_string()),
            ssh_user: "diego".to_string(),
            ssh_key: PathBuf::from("~/.ssh/google_compute_engine"),
            ssh_method: SshMethod::Gcloud,
            remote_path: PathBuf::from("/home/diego"),
            services: vec![],
            category: VmCategory::Free24x7,
        },
        Vm {
            name: "Oracle Dev".to_string(),
            alias: "dev".to_string(),
            provider: Provider::OCI,
            public_ip: "84.235.234.87".to_string(),
            wg_ip: Some("10.0.0.2".to_string()),
            ssh_user: "ubuntu".to_string(),
            ssh_key: PathBuf::from("~/.ssh/id_rsa"),
            ssh_method: SshMethod::Direct,
            remote_path: PathBuf::from("/home/ubuntu"),
            services: vec![],
            category: VmCategory::WakeOnDemand,
        },
        Vm {
            name: "Oracle Web".to_string(),
            alias: "web".to_string(),
            provider: Provider::OCI,
            public_ip: "130.110.251.193".to_string(),
            wg_ip: Some("10.0.0.3".to_string()),
            ssh_user: "ubuntu".to_string(),
            ssh_key: PathBuf::from("~/.ssh/id_rsa"),
            ssh_method: SshMethod::Direct,
            remote_path: PathBuf::from("/home/ubuntu"),
            services: vec![],
            category: VmCategory::Free24x7,
        },
        Vm {
            name: "Oracle Services".to_string(),
            alias: "services".to_string(),
            provider: Provider::OCI,
            public_ip: "129.151.228.66".to_string(),
            wg_ip: Some("10.0.0.4".to_string()),
            ssh_user: "ubuntu".to_string(),
            ssh_key: PathBuf::from("~/.ssh/id_rsa"),
            ssh_method: SshMethod::Direct,
            remote_path: PathBuf::from("/home/ubuntu"),
            services: vec![],
            category: VmCategory::Free24x7,
        },
    ]
}
