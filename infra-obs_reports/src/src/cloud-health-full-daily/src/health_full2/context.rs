use super::types::*;
use anyhow::{Context as _, Result};
use reports_common::context::find_cloud_data_file;
use serde_json::Value;
use std::collections::HashMap;

const BUILD_JSON_GLOB: &str = "/home/diego/Mounts/Git/cloud/a_solutions";
const BEARER_TOKEN_PATH: &str = "Mounts/Git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

pub fn load_context() -> Result<Context> {
    let cons_path = find_cloud_data_file("_cloud-data-consolidated.json")
        .context("_cloud-data-consolidated.json not found (walked up from cwd)")?;
    let raw = std::fs::read_to_string(&cons_path)
        .with_context(|| format!("reading {}", cons_path.display()))?;
    let c: Value = serde_json::from_str(&raw)?;

    // Migrated to build-reports.json:.topology (single derived file).
    // Legacy cloud-data-topology.json fallback during migration window.
    let topology = reports_common::context::load_topology();

    let caddy_routes_json = find_cloud_data_file("build-caddy.json")
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str::<Value>(&s).ok());

    // Build VM alias map: vm_id -> ssh_alias
    let mut vm_alias_map: HashMap<String, String> = HashMap::new();

    // Parse VMs
    let vms: Vec<VmInfo> = c["vms"]
        .as_object()
        .unwrap_or(&serde_json::Map::new())
        .iter()
        .filter_map(|(id, vm)| {
            let wg_ip = vm["wg_ip"].as_str().unwrap_or("").to_string();
            if wg_ip.is_empty() || wg_ip == "?" {
                return None;
            }

            let alias = vm["ssh_alias"].as_str().unwrap_or(id).to_string();
            vm_alias_map.insert(id.clone(), alias.clone());

            let provider = if id.starts_with("oci-") {
                "OCI"
            } else if id.starts_with("gcp-") {
                "GCP"
            } else {
                "?"
            };
            let cost = if id.contains("-f_") || id.contains("-f-") {
                "Free"
            } else if id.contains("-p_") {
                "Spot"
            } else {
                "?"
            };

            let declared_services: Vec<String> = vm["services"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();

            let public_ports: Vec<PublicPort> = vm["public_ports"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .map(|p| PublicPort {
                            port: p["port"].as_u64().unwrap_or(0) as u16,
                            proto: p["proto"].as_str().unwrap_or("tcp").to_string(),
                            desc: p["desc"].as_str().unwrap_or("").to_string(),
                        })
                        .collect()
                })
                .unwrap_or_default();

            Some(VmInfo {
                vm_id: id.clone(),
                alias,
                pub_ip: vm["ip"].as_str().unwrap_or("?").to_string(),
                wg_ip,
                cloud_name: vm["specs"]["cloud_name"]
                    .as_str()
                    .unwrap_or("?")
                    .to_string(),
                cloud_zone: vm["specs"]["cloud_zone"]
                    .as_str()
                    .unwrap_or("?")
                    .to_string(),
                rescue_port: vm["rescue_port"].as_u64().unwrap_or(2200) as u16,
                cpus: vm["specs"]["cpu"].as_u64().unwrap_or(0) as u32,
                ram_gb: vm["specs"]["ram_gb"].as_f64().unwrap_or(0.0),
                shape: vm["specs"]["shape"]
                    .as_str()
                    .or(vm["specs"]["machine_type"].as_str())
                    .unwrap_or("?")
                    .to_string(),
                provider: provider.to_string(),
                cost: cost.to_string(),
                declared_services,
                public_ports,
            })
        })
        .collect();

    // Parse services
    let services: Vec<ServiceInfo> = c["services"]
        .as_object()
        .unwrap_or(&serde_json::Map::new())
        .iter()
        .map(|(name, svc)| {
            let vm_id = svc["vm"].as_str().unwrap_or("").to_string();
            let vm_alias = vm_alias_map
                .get(&vm_id)
                .cloned()
                .unwrap_or_else(|| vm_id.clone());

            let containers: Vec<ContainerDecl> = svc["containers"]
                .as_object()
                .unwrap_or(&serde_json::Map::new())
                .iter()
                .map(|(key, ct)| ContainerDecl {
                    key: key.clone(),
                    container_name: ct["container_name"]
                        .as_str()
                        .unwrap_or("?")
                        .to_string(),
                    image: ct["image"].as_str().unwrap_or("?").to_string(),
                    port: ct["port"].as_u64().map(|p| p as u16),
                    dns: ct["dns"].as_str().map(|s| s.to_string()),
                    healthcheck: ct["healthcheck"].as_str().map(|s| s.to_string()),
                    // Declarative "expected to exit" signal (B5) — overrides the
                    // name-based `_setup`/`-setup`/`_init` heuristic in layers.rs.
                    init_job: ct["init_job"].as_bool().unwrap_or(false)
                        || ct["one_shot"].as_bool().unwrap_or(false),
                    // WG-only flag — skip cross-VM public probes when false (B7).
                    public: ct["public"].as_bool().unwrap_or(true),
                })
                .collect();

            ServiceInfo {
                name: name.clone(),
                category: svc["category"].as_str().unwrap_or("?").to_string(),
                vm_id,
                vm_alias,
                folder: svc["folder"].as_str().unwrap_or("").to_string(),
                domain: svc["domain"].as_str().map(|s| s.to_string()),
                port: svc["port"].as_u64().map(|p| p as u16),
                dns: svc["dns"].as_str().map(|s| s.to_string()),
                upstream: svc["upstream"].as_str().map(|s| s.to_string()),
                containers,
                enabled: svc["enabled"].as_bool().unwrap_or(true),
            }
        })
        .collect();

    // Parse caddy routes
    let caddy_route_list: Vec<CaddyRoute> = caddy_routes_json
        .as_ref()
        .and_then(|cr| cr["routes"].as_array())
        .map(|routes| {
            routes
                .iter()
                .map(|r| CaddyRoute {
                    domain: r["domain"].as_str().unwrap_or("").to_string(),
                    upstream: r["upstream"].as_str().unwrap_or("").to_string(),
                    comment: r["comment"].as_str().unwrap_or("").to_string(),
                    auth: r["auth"].as_str().map(|s| s.to_string()),
                })
                .collect()
        })
        .unwrap_or_default();

    // Scan build.json files for ports
    let service_ports = scan_build_json_ports(BUILD_JSON_GLOB);

    // Bearer token
    let home = std::env::var("HOME").unwrap_or("/home/diego".into());
    let bearer_token = std::fs::read_to_string(format!("{}/{}", home, BEARER_TOKEN_PATH))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v["access_token"].as_str().map(|s| s.to_string()));

    Ok(Context {
        consolidated: c,
        topology,
        caddy_routes: caddy_routes_json,
        vms,
        services,
        caddy_route_list,
        service_ports,
        bearer_token,
    })
}

/// Scan /home/diego/Mounts/Git/cloud/a_solutions/*/build.json for ports.app
fn scan_build_json_ports(base: &str) -> HashMap<String, u16> {
    let mut ports = HashMap::new();
    let Ok(entries) = std::fs::read_dir(base) else {
        return ports;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let build_json = path.join("build.json");
        if !build_json.exists() {
            continue;
        }
        let Ok(raw) = std::fs::read_to_string(&build_json) else {
            continue;
        };
        let Ok(j) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };

        // Service name from build.json "name" field or folder name
        let folder_name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let svc_name = j["name"]
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                // Strip category prefix: "aa-sui_code-server" -> "code-server"
                folder_name
                    .split('_')
                    .skip(1)
                    .collect::<Vec<_>>()
                    .join("_")
            });

        // ports.app field
        if let Some(port) = j["ports"]["app"].as_u64() {
            ports.insert(svc_name, port as u16);
        }
    }
    ports
}
