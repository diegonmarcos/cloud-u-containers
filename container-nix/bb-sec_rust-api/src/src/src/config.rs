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
    pub oci_namespace: String,
    pub oci_storage_quota_gb: f64,
    pub gcp_service_account_file: String,
    pub gcp_project_id: String,
    pub flex_vm_id: String,
    pub flex_services: HashMap<String, FlexService>,
    pub all_vm_services: HashMap<String, VmServiceMap>,
    pub route_check_domains: Vec<RouteCheckDomain>,
    pub authelia_bearer_token: Option<String>,
    pub container_domain_map: HashMap<String, String>,
}

#[derive(Clone, Debug)]
pub struct RouteCheckDomain {
    pub domain: String,
    pub service: String,
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

// ── config.json serde structs ──────────────────────────────────────────

#[derive(Deserialize)]
struct ConfigJson {
    #[allow(dead_code)]
    ssh_key: Option<String>,
    vms: HashMap<String, ConfigVm>,
    services: HashMap<String, ConfigService>,
}

#[derive(Deserialize)]
struct ConfigVm {
    ip: String,
    wg_ip: Option<String>,
    user: String,
    method: String,
    ssh_alias: String,
    gcloud_instance: Option<String>,
    gcloud_zone: Option<String>,
}

#[derive(Deserialize)]
struct ConfigService {
    vm: String,
    containers: Option<Vec<String>>,
    domain: Option<String>,
    #[allow(dead_code)]
    category: Option<String>,
}

fn load_config_json(path: &str) -> Option<ConfigJson> {
    if !Path::new(path).exists() {
        tracing::warn!("config.json not found at {path}");
        return None;
    }
    match std::fs::read_to_string(path) {
        Ok(content) => match serde_json::from_str(&content) {
            Ok(cfg) => Some(cfg),
            Err(e) => {
                tracing::warn!("Failed to parse config.json: {e}");
                None
            }
        },
        Err(e) => {
            tracing::warn!("Failed to read config.json: {e}");
            None
        }
    }
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
            ("oci-A1-f_0", "OCI_FLEX0_INSTANCE_ID"),
            ("oci-A1-f_1", "OCI_FLEX1_INSTANCE_ID"),
            ("oci-A1-p_0", "OCI_PAID_FLEX0_INSTANCE_ID"),
            ("oci-E2-f_0", "OCI_MICRO1_INSTANCE_ID"),
            ("oci-E2-f_1", "OCI_MICRO2_INSTANCE_ID"),
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
            if let Some(vms) = &arch.virtual_machines {
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

        // GCP config
        let gcp_service_account_file = std::env::var("GCP_SERVICE_ACCOUNT_FILE")
            .unwrap_or_else(|_| "/app/config/gcp_key.json".into());
        let gcp_project_id = std::env::var("GCP_PROJECT_ID").unwrap_or_default();

        // SSH key paths from env
        let ssh_key = std::env::var("SSH_KEY_PATH")
            .unwrap_or_else(|_| "/app/config/id_rsa".into());
        let gcp_key = std::env::var("GCP_SSH_KEY_PATH")
            .unwrap_or_else(|_| "/app/config/gcp_key".into());

        // ── Load config.json — derive all VM/service maps dynamically ──

        let config_json_path = std::env::var("CONFIG_JSON_PATH")
            .unwrap_or_else(|_| "/app/config/config.json".into());

        let mut vm_ssh = HashMap::new();
        let mut gcp_vms = HashMap::new();
        let mut all_vm_services = HashMap::new();
        let mut route_check_domains = Vec::new();
        let mut container_domain_map = HashMap::new();

        if let Some(cfg) = load_config_json(&config_json_path) {
            // 1. Derive vm_ssh: use wg_ip (preferred) or public ip as host
            for (vm_id, vm) in &cfg.vms {
                let host = match &vm.wg_ip {
                    Some(wg) => wg.clone(),
                    None if vm.ip != "TBD" => vm.ip.clone(),
                    _ => continue, // skip VMs with no reachable IP
                };
                let key = if vm.method == "gcloud" {
                    gcp_key.clone()
                } else {
                    ssh_key.clone()
                };
                vm_ssh.insert(vm_id.clone(), SshConfig {
                    host,
                    user: vm.user.clone(),
                    key_path: key,
                });
            }

            // 2. Derive gcp_vms from VMs with method == "gcloud"
            for (vm_id, vm) in &cfg.vms {
                if vm.method == "gcloud" {
                    if let (Some(instance), Some(zone)) = (&vm.gcloud_instance, &vm.gcloud_zone) {
                        gcp_vms.insert(vm_id.clone(), GcpVm {
                            name: instance.clone(),
                            zone: zone.clone(),
                            project_id: gcp_project_id.clone(),
                        });
                    }
                }
            }

            // Ensure GCP VMs are in vm_instances for provider dispatch
            for (vm_id, gcp_vm) in &gcp_vms {
                vm_instances.entry(vm_id.clone()).or_insert_with(|| VmInstance {
                    instance_id: gcp_vm.name.clone(),
                    provider: VmProvider::Gcp,
                });
            }

            // 3. Derive all_vm_services: group services by vm, use ssh_alias as label
            let mut vm_svc_groups: HashMap<String, HashMap<String, Vec<String>>> = HashMap::new();
            for (svc_name, svc) in &cfg.services {
                if svc.vm == "all" || svc.vm == "local" {
                    continue;
                }
                let containers = svc.containers.clone().unwrap_or_default();
                vm_svc_groups
                    .entry(svc.vm.clone())
                    .or_default()
                    .insert(svc_name.clone(), containers);
            }
            for (vm_id, services) in vm_svc_groups {
                let label = cfg.vms.get(&vm_id)
                    .map(|v| v.ssh_alias.clone())
                    .unwrap_or_else(|| vm_id.clone());
                all_vm_services.insert(vm_id, VmServiceMap { label, services });
            }

            // 4. Derive route_check_domains from services with a domain
            for (svc_name, svc) in &cfg.services {
                if let Some(domain) = &svc.domain {
                    route_check_domains.push(RouteCheckDomain {
                        domain: domain.clone(),
                        service: svc_name.clone(),
                    });
                }
            }

            // 5. Derive container_domain_map: first container -> domain
            for (_svc_name, svc) in &cfg.services {
                if let (Some(domain), Some(containers)) = (&svc.domain, &svc.containers) {
                    if let Some(first) = containers.first() {
                        container_domain_map.insert(first.clone(), domain.clone());
                    }
                }
            }

            tracing::info!(
                "Loaded config.json: {} VMs, {} services, {} SSH configs, {} GCP VMs",
                cfg.vms.len(),
                cfg.services.len(),
                vm_ssh.len(),
                gcp_vms.len(),
            );
        } else {
            tracing::warn!("config.json not loaded — health checks will have no VM/service data");
        }

        // Derive flex_services from oci-A1-f_1 (wake-on-demand VM)
        let flex_services: HashMap<String, FlexService> = all_vm_services
            .get("oci-A1-f_1")
            .map(|vm_map| {
                vm_map.services.iter()
                    .map(|(k, v)| (k.clone(), FlexService { containers: v.clone() }))
                    .collect()
            })
            .unwrap_or_default();

        let authelia_bearer_token = std::env::var("AUTHELIA_BEARER_TOKEN").ok()
            .filter(|s| !s.is_empty());

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
            oci_namespace: std::env::var("OCI_NAMESPACE")
                .unwrap_or_else(|_| "axpmn3qtq4ig".into()),
            oci_storage_quota_gb: std::env::var("OCI_STORAGE_QUOTA_GB")
                .ok().and_then(|s| s.parse().ok()).unwrap_or(10240.0),
            gcp_service_account_file,
            gcp_project_id,
            flex_vm_id: "oci-A1-f_1".to_string(),
            flex_services,
            all_vm_services,
            route_check_domains,
            authelia_bearer_token,
            container_domain_map,
        }
    }
}
