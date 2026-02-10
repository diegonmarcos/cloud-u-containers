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
    pub gcp_service_account_file: String,
    pub gcp_project_id: String,
    pub flex_vm_id: String,
    pub flex_services: HashMap<String, FlexService>,
    pub all_vm_services: HashMap<String, VmServiceMap>,
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
    pub project_id: String,
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

#[derive(Clone, Debug)]
pub struct VmServiceMap {
    pub label: String,
    pub services: HashMap<String, Vec<String>>,
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

        let architecture: Option<Architecture> = if Path::new(&arch_path).exists() {
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

        // GCP config
        let gcp_service_account_file = std::env::var("GCP_SERVICE_ACCOUNT_FILE")
            .unwrap_or_else(|_| "/app/config/gcp_key.json".into());
        let gcp_project_id = std::env::var("GCP_PROJECT_ID").unwrap_or_default();

        // GCP VMs
        let mut gcp_vms = HashMap::new();
        gcp_vms.insert("gcp-f-micro_1".to_string(), GcpVm {
            name: "arch-1".to_string(),
            zone: "us-central1-a".to_string(),
            project_id: gcp_project_id.clone(),
        });

        // Ensure GCP VMs are in vm_instances for provider dispatch
        for (vm_id, gcp_vm) in &gcp_vms {
            vm_instances.entry(vm_id.clone()).or_insert_with(|| VmInstance {
                instance_id: gcp_vm.name.clone(),
                provider: VmProvider::Gcp,
            });
        }

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

        // All VM service maps
        let mut all_vm_services = HashMap::new();

        // oci-p-flex_1 (oci-flex)
        let mut flex_svc = HashMap::new();
        flex_svc.insert("photos".into(), vec!["photoprism_app".into(), "photoprism_mariadb".into()]);
        flex_svc.insert("calendar".into(), vec!["radicale".into()]);
        flex_svc.insert("hedgedoc".into(), vec!["hedgedoc_app".into(), "hedgedoc_postgres".into()]);
        flex_svc.insert("etherpad".into(), vec!["etherpad_app".into(), "etherpad_postgres".into()]);
        flex_svc.insert("grist".into(), vec!["grist_app".into()]);
        flex_svc.insert("files".into(), vec!["filebrowser_app".into()]);
        flex_svc.insert("slides".into(), vec!["revealmd_app".into()]);
        flex_svc.insert("code".into(), vec!["code-server".into()]);
        flex_svc.insert("nocodb".into(), vec!["nocodb_app".into(), "nocodb_postgres".into()]);
        flex_svc.insert("monitoring".into(), vec!["lgtm_grafana".into(), "lgtm_loki".into(), "lgtm_mimir".into(), "lgtm_tempo".into()]);
        flex_svc.insert("git".into(), vec!["gitea".into()]);
        flex_svc.insert("cache".into(), vec!["redis".into()]);
        flex_svc.insert("security".into(), vec!["sauron".into()]);
        flex_svc.insert("logs".into(), vec!["fluent-bit".into()]);
        all_vm_services.insert("oci-p-flex_1".into(), VmServiceMap {
            label: "oci-flex".into(),
            services: flex_svc,
        });

        // gcp-f-micro_1 (gcp-proxy)
        let mut gcp_svc = HashMap::new();
        gcp_svc.insert("proxy".into(), vec!["npm".into(), "introspect-proxy".into()]);
        gcp_svc.insert("auth".into(), vec!["authelia".into(), "authelia-redis".into()]);
        gcp_svc.insert("api".into(), vec!["flask-api".into()]);
        gcp_svc.insert("notifications".into(), vec!["ntfy".into()]);
        gcp_svc.insert("passwords".into(), vec!["vaultwarden".into()]);
        gcp_svc.insert("logs".into(), vec!["fluent-bit".into()]);
        all_vm_services.insert("gcp-f-micro_1".into(), VmServiceMap {
            label: "gcp-proxy".into(),
            services: gcp_svc,
        });

        // oci-f-micro_1 (oci-mail)
        let mut mail_svc = HashMap::new();
        mail_svc.insert("mail".into(), vec![
            "mailu-front-1".into(), "mailu-admin-1".into(), "mailu-imap-1".into(),
            "mailu-smtp-1".into(), "mailu-antispam-1".into(), "mailu-webmail-1".into(),
            "mailu-redis-1".into(), "mailu-resolver-1".into(),
        ]);
        mail_svc.insert("calendar".into(), vec!["radicale".into()]);
        mail_svc.insert("smtp_proxy".into(), vec!["smtp-proxy".into()]);
        mail_svc.insert("sync".into(), vec!["syncthing".into()]);
        mail_svc.insert("analytics".into(), vec!["matomo-app".into(), "matomo-db".into()]);
        mail_svc.insert("proxy".into(), vec!["nginx-proxy".into()]);
        mail_svc.insert("logs".into(), vec!["fluent-bit".into(), "syslog-forwarder".into()]);
        all_vm_services.insert("oci-f-micro_1".into(), VmServiceMap {
            label: "oci-mail".into(),
            services: mail_svc,
        });

        // oci-f-micro_2 (oci-analytics)
        let mut analytics_svc = HashMap::new();
        analytics_svc.insert("analytics".into(), vec!["matomo-hybrid".into()]);
        analytics_svc.insert("security".into(), vec!["sauron".into(), "sauron-forwarder".into()]);
        analytics_svc.insert("automation".into(), vec!["windmill-server".into(), "windmill-worker".into(), "windmill-db".into()]);
        analytics_svc.insert("logs".into(), vec!["fluent-bit".into(), "syslog-forwarder".into()]);
        all_vm_services.insert("oci-f-micro_2".into(), VmServiceMap {
            label: "oci-analytics".into(),
            services: analytics_svc,
        });

        // Derive flex_services from oci-p-flex_1
        let flex_services: HashMap<String, FlexService> = all_vm_services["oci-p-flex_1"]
            .services
            .iter()
            .map(|(k, v)| (k.clone(), FlexService { containers: v.clone() }))
            .collect();

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
            gcp_service_account_file,
            gcp_project_id,
            flex_vm_id: "oci-p-flex_1".to_string(),
            flex_services,
            all_vm_services,
        }
    }
}
