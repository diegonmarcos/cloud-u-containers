use crate::types::{DomainInfo, NetworkInfo, VmInfo};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::path::Path;

/// Cloud infrastructure configuration
#[derive(Debug, Clone)]
pub struct CloudConfig {
    // VMs
    pub vms: Vec<VmInfo>,
    pub vm_ips: HashMap<String, String>,

    // Networks
    pub networks: Vec<NetworkInfo>,

    // Domains
    pub domains: Vec<DomainInfo>,
    pub domain_list: Vec<String>,

    // SMTP configuration
    pub to_email: String,
    pub from_email: String,
    pub smtp_user: String,
    pub smtp_pass: Option<String>,
    pub smtp_proxy_url: String,
    pub smtp_proxy_key: String,

    // SSH keys
    pub ssh_key_oci: String,
    pub ssh_key_gcp: String,
}

impl CloudConfig {
    pub fn load() -> Result<Self> {
        // Load from config file if exists
        let config_path = "/app/config/endpoints.conf";
        if Path::new(config_path).exists() {
            Self::load_from_file(config_path)
        } else {
            // Fallback to environment variables
            Self::load_from_env()
        }
    }

    fn load_from_file(path: &str) -> Result<Self> {
        // Read file and parse key=value pairs
        let content = std::fs::read_to_string(path)
            .context(format!("Failed to read config file: {}", path))?;

        let mut vars = HashMap::new();
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            if let Some((key, value)) = line.split_once('=') {
                let key = key.trim();
                // Remove inline comments and trim
                let value = value.split('#').next().unwrap_or(value);
                let value = value.trim().trim_matches('"');
                vars.insert(key.to_string(), value.to_string());
            }
        }

        Self::build_from_vars(&vars)
    }

    fn load_from_env() -> Result<Self> {
        dotenv::dotenv().ok();
        let vars: HashMap<String, String> = std::env::vars().collect();
        Self::build_from_vars(&vars)
    }

    fn build_from_vars(vars: &HashMap<String, String>) -> Result<Self> {
        // VM IPs
        let oci_micro_1 = vars
            .get("OCI_MICRO_1")
            .cloned()
            .unwrap_or_else(|| "130.110.251.193".to_string());
        let oci_micro_2 = vars
            .get("OCI_MICRO_2")
            .cloned()
            .unwrap_or_else(|| "129.151.228.66".to_string());
        let gcp_micro_1 = vars
            .get("GCP_MICRO_1")
            .cloned()
            .unwrap_or_else(|| "35.226.147.64".to_string());
        let oci_flex_1 = vars
            .get("OCI_FLEX_1")
            .cloned()
            .unwrap_or_else(|| "84.235.234.87".to_string());

        // Build VM info
        let vms = vec![
            VmInfo::new(
                "oci-f-micro_1",
                "OCI",
                &oci_micro_1,
                "1GB",
                "Mail Server",
                vec!["Mailu".to_string()],
            ),
            VmInfo::new(
                "oci-f-micro_2",
                "OCI",
                &oci_micro_2,
                "1GB",
                "Analytics",
                vec!["Matomo".to_string()],
            ),
            VmInfo::new(
                "gcp-f-micro_1",
                "GCP",
                &gcp_micro_1,
                "1GB",
                "Proxy/Auth",
                vec!["NPM".to_string(), "Authelia".to_string(), "ntfy".to_string()],
            ),
            VmInfo::new(
                "oci-p-flex_1",
                "OCI",
                &oci_flex_1,
                "8GB",
                "Media",
                vec![
                    "Photoprism".to_string(),
                    "Syncthing".to_string(),
                    "Radicale".to_string(),
                ],
            )
            .with_mode("wake-on-demand"),
        ];

        let mut vm_ips = HashMap::new();
        vm_ips.insert("oci-micro-1".to_string(), oci_micro_1.clone());
        vm_ips.insert("oci-micro-2".to_string(), oci_micro_2.clone());
        vm_ips.insert("gcp-micro-1".to_string(), gcp_micro_1.clone());
        vm_ips.insert("oci-flex-1".to_string(), oci_flex_1.clone());

        // Networks
        let networks = vec![
            NetworkInfo {
                name: "mail_network".to_string(),
                subnet: "172.20.0.0/24".to_string(),
                vm: "oci-f-micro_1".to_string(),
            },
            NetworkInfo {
                name: "matomo_network".to_string(),
                subnet: "172.21.0.0/24".to_string(),
                vm: "oci-f-micro_2".to_string(),
            },
            NetworkInfo {
                name: "npm_default".to_string(),
                subnet: "172.18.0.0/24".to_string(),
                vm: "gcp-f-micro_1".to_string(),
            },
            NetworkInfo {
                name: "dev_network".to_string(),
                subnet: "172.24.0.0/24".to_string(),
                vm: "oci-p-flex_1".to_string(),
            },
        ];

        // Domains
        let domain_list = vec![
            "mail".to_string(),
            "analytics".to_string(),
            "proxy".to_string(),
            "auth".to_string(),
            "rss".to_string(),
            "cloud".to_string(),
            "photos".to_string(),
            "sync".to_string(),
            "cal".to_string(),
        ];

        let domains = vec![
            DomainInfo {
                domain: "diegonmarcos.com".to_string(),
                purpose: "Root domain (Cloudflare DNS)".to_string(),
            },
            DomainInfo {
                domain: "mail.*.com".to_string(),
                purpose: "Email services (Mailu)".to_string(),
            },
            DomainInfo {
                domain: "analytics.*.com".to_string(),
                purpose: "Web analytics (Matomo)".to_string(),
            },
            DomainInfo {
                domain: "proxy.*.com".to_string(),
                purpose: "Reverse proxy admin (NPM)".to_string(),
            },
            DomainInfo {
                domain: "auth.*.com".to_string(),
                purpose: "2FA gateway (Authelia)".to_string(),
            },
            DomainInfo {
                domain: "rss.*.com".to_string(),
                purpose: "Push notifications (ntfy)".to_string(),
            },
            DomainInfo {
                domain: "photos.app.*.com".to_string(),
                purpose: "Photo management (wake-on-demand)".to_string(),
            },
        ];

        // SMTP
        let to_email = vars
            .get("TO_EMAIL")
            .cloned()
            .unwrap_or_else(|| "me@diegonmarcos.com".to_string());
        let from_email = vars
            .get("FROM_EMAIL")
            .cloned()
            .unwrap_or_else(|| "no-reply@diegonmarcos.com".to_string());
        let smtp_user = vars
            .get("SMTP_USER")
            .cloned()
            .unwrap_or_else(|| from_email.clone());
        let smtp_pass = vars.get("SMTP_PASS").cloned();
        let smtp_proxy_url = vars
            .get("SMTP_PROXY_URL")
            .cloned()
            .unwrap_or_else(|| "http://smtp.diegonmarcos.com:8080/".to_string());
        let smtp_proxy_key = vars
            .get("SMTP_PROXY_KEY")
            .cloned()
            .unwrap_or_else(|| "stalwart-proxy-key-2025".to_string());

        // SSH keys
        let ssh_key_oci = vars
            .get("SSH_KEY_OCI")
            .cloned()
            .unwrap_or_else(|| "/root/.ssh/id_rsa".to_string());
        let ssh_key_gcp = vars
            .get("SSH_KEY_GCP")
            .cloned()
            .unwrap_or_else(|| "/root/.ssh/google_compute_engine".to_string());

        Ok(Self {
            vms,
            vm_ips,
            networks,
            domains,
            domain_list,
            to_email,
            from_email,
            smtp_user,
            smtp_pass,
            smtp_proxy_url,
            smtp_proxy_key,
            ssh_key_oci,
            ssh_key_gcp,
        })
    }

    pub fn get_vm_ip(&self, vm_id: &str) -> Option<&str> {
        self.vm_ips.get(vm_id).map(|s| s.as_str())
    }
}
