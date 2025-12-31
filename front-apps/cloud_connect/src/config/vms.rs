//! VM and Service definitions

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Virtual Machine definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Vm {
    /// Display name
    pub name: String,

    /// Short alias for CLI
    pub alias: String,

    /// Cloud provider
    pub provider: Provider,

    /// Public IP address
    pub public_ip: String,

    /// WireGuard VPN IP (optional)
    pub wg_ip: Option<String>,

    /// SSH username
    pub ssh_user: String,

    /// Path to SSH key
    pub ssh_key: PathBuf,

    /// SSH connection method
    pub ssh_method: SshMethod,

    /// Remote path to mount
    pub remote_path: PathBuf,

    /// Services running on this VM
    #[serde(default)]
    pub services: Vec<Service>,

    /// VM category
    pub category: VmCategory,
}

impl Vm {
    /// Get the IP to use (prefer WireGuard if available)
    pub fn preferred_ip(&self, vpn_connected: bool) -> &str {
        if vpn_connected {
            self.wg_ip.as_deref().unwrap_or(&self.public_ip)
        } else {
            &self.public_ip
        }
    }

    /// Get mount point path
    pub fn mount_point(&self, base: &std::path::Path) -> PathBuf {
        base.join(&self.alias)
    }
}

/// Cloud provider
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    GCP,
    OCI,
    AWS,
    Azure,
    Hetzner,
}

impl std::fmt::Display for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Provider::GCP => write!(f, "GCP"),
            Provider::OCI => write!(f, "OCI"),
            Provider::AWS => write!(f, "AWS"),
            Provider::Azure => write!(f, "Azure"),
            Provider::Hetzner => write!(f, "Hetzner"),
        }
    }
}

/// SSH connection method
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SshMethod {
    /// Use gcloud compute ssh
    Gcloud,
    /// Use direct ssh -i
    Direct,
}

/// VM availability category
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VmCategory {
    /// Always running, free tier
    Free24x7,
    /// Always running, paid
    Paid,
    /// Wake on demand
    WakeOnDemand,
}

impl std::fmt::Display for VmCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VmCategory::Free24x7 => write!(f, "Free (24/7)"),
            VmCategory::Paid => write!(f, "Paid"),
            VmCategory::WakeOnDemand => write!(f, "Wake-on-Demand"),
        }
    }
}

/// Service definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Service {
    /// Service name
    pub name: String,

    /// Domain (optional)
    pub domain: Option<String>,

    /// Port number
    pub port: u16,

    /// Docker container name (optional)
    pub container: Option<String>,

    /// Health check endpoint (optional)
    pub health_endpoint: Option<String>,

    /// Current status
    #[serde(default)]
    pub status: ServiceStatus,
}

/// Service status
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ServiceStatus {
    Running,
    Stopped,
    #[default]
    Unknown,
}

impl std::fmt::Display for ServiceStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ServiceStatus::Running => write!(f, "Running"),
            ServiceStatus::Stopped => write!(f, "Stopped"),
            ServiceStatus::Unknown => write!(f, "Unknown"),
        }
    }
}
