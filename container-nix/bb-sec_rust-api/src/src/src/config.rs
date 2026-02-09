use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub port: u16,
    pub architecture: Option<Architecture>,
    pub vm_instances: HashMap<String, VmInstance>,
    pub gcp_vms: HashMap<String, GcpVm>,
    pub vm_ssh: HashMap<String, SshConfig>,
    pub oci_config_file: String,
    pub oci_key_file: String,
    pub cf_api_token: String,
    pub cf_zone_id: String,
    pub flex_vm_id: String,
    pub flex_services: HashMap<String, FlexService>,
}

#[derive(Clone, Debug)]
pub struct VmInstance {
    pub instance_id: String,
    pub provider: VmProvider,
}

#[derive(Clone, Debug)]
pub enum VmProvider {
    Oci,
    Gcp,
}

#[derive(Clone, Debug)]
pub struct GcpVm {
    pub name: String,
    pub zone: String,
}

#[derive(Clone, Debug)]
pub struct SshConfig {
    pub host: String,
    pub user: String,
    pub key_path: String,
}

#[derive(Clone, Debug)]
pub struct FlexService {
    pub containers: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Architecture {
    #[serde(rename = "partII_infrastructure")]
    pub infrastructure: Option<InfraSection>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct InfraSection {
    #[serde(rename = "virtualMachines")]
    pub virtual_machines: Option<HashMap<String, VmData>>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct VmData {
    pub provider: Option<String>,
    #[serde(rename = "ociInstanceId")]
    pub oci_instance_id: Option<String>,
    pub network: Option<NetworkData>,
    pub ssh: Option<SshData>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct NetworkData {
    #[serde(rename = "publicIp")]
    pub public_ip: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SshData {
    pub user: Option<String>,
    #[serde(rename = "keyPath")]
    pub key_path: Option<String>,
}

impl AppConfig {
    pub fn load() -> Self {
        let port = std::env::var("RUST_API_PORT")
            .unwrap_or_else(|_| "8080".into())
            .parse()
            .unwrap_or(8080);

        let arch_path = std::env::var("CLOUD_CONFIG_PATH")
            .unwrap_or_else(|_| "/app/config/architecture.json".into());

        let architecture = if Path::new(&arch_path).exists() {
            match std::fs::read_to_string(&arch_path) {
                Ok(content) => serde_json::from_str(&content).ok(),
                Err(e) => {
                    tracing::warn!("Failed to read architecture.json: {e}");
                    None
                }
            }
        } else {
            tracing::warn!("architecture.json not found at {arch_path}");
            None
        };

        // OCI instance IDs from env
        let mut vm_instances = HashMap::new();
        let oci_vms = [
            ("oci-p-flex_1", "OCI_FLEX1_INSTANCE_ID"),
            ("oci-f-micro_1", "OCI_MICRO1_INSTANCE_ID"),
            ("oci-f-micro_2", "OCI_MICRO2_INSTANCE_ID"),
        ];
        for (vm_id, env_key) in oci_vms {
            if let Ok(id) = std::env::var(env_key) {
                if !id.is_empty() {
                    vm_instances.insert(vm_id.to_string(), VmInstance {
                        instance_id: id,
                        provider: VmProvider::Oci,
                    });
                }
            }
        }

        // Also try to load from architecture.json
        if let Some(arch) = &architecture {
            if let Some(infra) = &arch.infrastructure {
                if let Some(vms) = &infra.virtual_machines {
                    for (vm_id, data) in vms {
                        if vm_instances.contains_key(vm_id) {
                            continue; // env vars take precedence
                        }
                        if let Some(oci_id) = &data.oci_instance_id {
                            let provider = match data.provider.as_deref() {
                                Some("gcloud") => VmProvider::Gcp,
                                _ => VmProvider::Oci,
                            };
                            vm_instances.insert(vm_id.clone(), VmInstance {
                                instance_id: oci_id.clone(),
                                provider,
                            });
                        }
                    }
                }
            }
        }

        // GCP VMs
        let mut gcp_vms = HashMap::new();
        gcp_vms.insert("gcp-f-micro_1".to_string(), GcpVm {
            name: "arch-1".to_string(),
            zone: "us-central1-a".to_string(),
        });

        // SSH configs from env or architecture.json
        let mut vm_ssh = HashMap::new();
        let ssh_key = std::env::var("SSH_KEY_PATH")
            .unwrap_or_else(|_| "/app/config/id_rsa".into());
        let gcp_key = std::env::var("GCP_SSH_KEY_PATH")
            .unwrap_or_else(|_| "/app/config/gcp_key".into());

        let default_ssh = vec![
            ("oci-p-flex_1", "84.235.234.87", "ubuntu", ssh_key.as_str()),
            ("oci-f-micro_1", "130.110.251.193", "ubuntu", ssh_key.as_str()),
            ("oci-f-micro_2", "129.151.228.66", "ubuntu", ssh_key.as_str()),
            ("gcp-f-micro_1", "34.55.55.234", "diego", gcp_key.as_str()),
        ];

        for (vm_id, host, user, key) in &default_ssh {
            vm_ssh.insert(vm_id.to_string(), SshConfig {
                host: host.to_string(),
                user: user.to_string(),
                key_path: key.to_string(),
            });
        }

        // Override from architecture.json if available
        if let Some(arch) = &architecture {
            if let Some(infra) = &arch.infrastructure {
                if let Some(vms) = &infra.virtual_machines {
                    for (vm_id, data) in vms {
                        if let (Some(network), Some(ssh)) = (&data.network, &data.ssh) {
                            if let Some(ip) = &network.public_ip {
                                if ip != "pending" {
                                    vm_ssh.insert(vm_id.clone(), SshConfig {
                                        host: ip.clone(),
                                        user: ssh.user.clone().unwrap_or_else(|| "ubuntu".into()),
                                        key_path: ssh_key.clone(),
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }

        // Flex services (containers on oci-p-flex_1)
        let mut flex_services = HashMap::new();
        flex_services.insert("sync".to_string(), FlexService {
            containers: vec!["syncthing".to_string()],
        });
        flex_services.insert("photos".to_string(), FlexService {
            containers: vec!["photoprism-app".to_string(), "photos-db".to_string()],
        });
        flex_services.insert("calendar".to_string(), FlexService {
            containers: vec!["radicale-app".to_string()],
        });
        flex_services.insert("cache".to_string(), FlexService {
            containers: vec!["cache-app".to_string()],
        });

        AppConfig {
            port,
            architecture,
            vm_instances,
            gcp_vms,
            vm_ssh,
            oci_config_file: std::env::var("OCI_CONFIG_FILE")
                .unwrap_or_else(|_| "/app/config/oci_config".into()),
            oci_key_file: std::env::var("OCI_KEY_FILE")
                .unwrap_or_else(|_| "/app/config/oci_api_key.pem".into()),
            cf_api_token: std::env::var("CF_API_TOKEN").unwrap_or_default(),
            cf_zone_id: std::env::var("CF_ZONE_ID").unwrap_or_default(),
            flex_vm_id: "oci-p-flex_1".to_string(),
            flex_services,
        }
    }
}
