use crate::types::*;
use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;

const BEARER_TOKEN_PATH: &str =
    "Mounts/Git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

/// Find a cloud-data JSON file. Search order:
///   1. `$CLOUD_DATA_DIR/<name>` (env override; also probes z_archive/ under it)
///   2. Walk up from cwd, checking `<dir>/<name>` AND `<dir>/z_archive/<name>`
///      (handles report binaries running with cwd=reports/dist; the cloud-data
///      pattern moves deprecated cloud-data-*.json into z_archive/ when they
///      stop being read by primary consumers but reports still need them).
///   3. Known fallback dirs (each probed at root AND at z_archive/):
///        a) ~/git/cloud-data/                       (this repo)
///        b) ~/git/cloud-infra/1_cloud-configs/dist/        (build-*.json + _cloud-data-consolidated.json)
///        c) ~/git/cloud-infra/I_cloud-data/               (submodule mirror, last-resort)
pub fn find_cloud_data_file(name: &str) -> Option<PathBuf> {
    let try_dir = |dir: &std::path::Path, name: &str| -> Option<PathBuf> {
        let direct = dir.join(name);
        if direct.exists() {
            return Some(direct);
        }
        let archived = dir.join("z_archive").join(name);
        if archived.exists() {
            return Some(archived);
        }
        None
    };

    if let Ok(dir) = std::env::var("CLOUD_DATA_DIR") {
        if let Some(p) = try_dir(std::path::Path::new(&dir), name) {
            return Some(p);
        }
    }
    let cwd = std::env::current_dir().ok();
    if let Some(cwd) = cwd {
        let mut cur = Some(cwd.as_path());
        while let Some(c) = cur {
            if let Some(p) = try_dir(c, name) {
                return Some(p);
            }
            cur = c.parent();
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/diego".into());
    let fallbacks = [
        format!("{}/git/cloud-data", home),
        format!("{}/git/cloud-infra/1_cloud-configs/dist", home),
        format!("{}/git/cloud-infra/I_cloud-data", home),
    ];
    for f in &fallbacks {
        if let Some(p) = try_dir(std::path::Path::new(f), name) {
            return Some(p);
        }
    }
    None
}

/// Load the consolidated cloud-data JSON
pub fn load_consolidated() -> Result<Value> {
    let path = find_cloud_data_file("_cloud-data-consolidated.json")
        .context("_cloud-data-consolidated.json not found (walked up from cwd)")?;
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("reading {}", path.display()))?;
    Ok(serde_json::from_str(&raw)?)
}

/// Load build-reports.json — single derived file (engine: cloud/2_configs/
/// src/engines/cloud-data-config-derive.ts/deriveBuildReports). Replaces
/// every legacy cloud-data-*.json read. Sections: endpoint_checks,
/// tls_checks, dns_checks, vms, services, dns_services, databases,
/// topology, url_health, workflows, repo_scan, sec_scan. Symlinked into
/// cloud-data/ via a relative path so consumers walking up land on the
/// live engine output, not stale snapshots.
pub fn load_build_reports() -> Option<Value> {
    find_cloud_data_file("build-reports.json")
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
}

/// Load a named section from build-reports.json. Returns None if the file
/// is missing OR the section isn't present.
pub fn load_build_reports_section(section: &str) -> Option<Value> {
    load_build_reports().and_then(|br| br.get(section).cloned())
}

/// Load topology JSON (optional). Migrated to build-reports.json:.topology;
/// falls back to legacy cloud-data-topology.json (now in z_archive) for
/// back-compat during the migration window.
pub fn load_topology() -> Option<Value> {
    load_build_reports_section("topology")
        .or_else(|| {
            find_cloud_data_file("cloud-data-topology.json")
                .and_then(|p| std::fs::read_to_string(p).ok())
                .and_then(|s| serde_json::from_str(&s).ok())
        })
}

/// Load caddy routes JSON (optional)
pub fn load_caddy_routes() -> Option<Value> {
    find_cloud_data_file("build-caddy.json")
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
}

/// Load DNS services JSON (optional). Migrated to
/// build-reports.json:.dns_services with legacy fallback.
pub fn load_dns_services() -> Option<Value> {
    load_build_reports_section("dns_services")
        .or_else(|| {
            find_cloud_data_file("cloud-data-dns-services.json")
                .and_then(|p| std::fs::read_to_string(p).ok())
                .and_then(|s| serde_json::from_str(&s).ok())
        })
}

/// Load the `tiers` block from build-reports.json (Phase 1). Returns None if
/// the file or section is absent — callers fall back to built-in defaults.
pub fn load_tiers() -> Option<Value> {
    load_build_reports_section("tiers")
}

/// Load the `resolvers` block from build-reports.json (R2). Returns None if
/// the file or section is absent — checks.rs then uses its FALLBACK_* consts.
pub fn load_resolvers() -> Option<Value> {
    load_build_reports_section("resolvers")
}

/// Load bearer token from vault
pub fn load_bearer_token() -> Option<String> {
    // Try env var first (GHA), then file (local)
    if let Ok(token) = std::env::var("BEARER_TOKEN") {
        if !token.is_empty() {
            return Some(token);
        }
    }
    let home = std::env::var("HOME").unwrap_or("/home/diego".into());
    std::fs::read_to_string(format!("{}/{}", home, BEARER_TOKEN_PATH))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v["access_token"].as_str().map(|s| s.to_string()))
}

/// Parse VMs from consolidated JSON
pub fn parse_vms(consolidated: &Value) -> Vec<VmInfo> {
    let mut vms = Vec::new();
    let empty_map = serde_json::Map::new();
    let vm_map = consolidated["vms"].as_object().unwrap_or(&empty_map);

    for (id, vm) in vm_map {
        let wg_ip = vm["wg_ip"].as_str().unwrap_or("").to_string();
        if wg_ip.is_empty() || wg_ip == "?" {
            continue;
        }

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
                        source: p["source"].as_str().unwrap_or("0.0.0.0/0").to_string(),
                    })
                    .collect()
            })
            .unwrap_or_default();

        vms.push(VmInfo {
            vm_id: id.clone(),
            alias: vm["ssh_alias"].as_str().unwrap_or(id).to_string(),
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
        });
    }

    vms
}

/// Parse services from consolidated JSON
pub fn parse_services(consolidated: &Value) -> Vec<ServiceInfo> {
    let empty_map = serde_json::Map::new();
    let svc_map = consolidated["services"].as_object().unwrap_or(&empty_map);

    // Build VM alias map
    let mut vm_alias_map: HashMap<String, String> = HashMap::new();
    if let Some(vms) = consolidated["vms"].as_object() {
        for (id, vm) in vms {
            let alias = vm["ssh_alias"].as_str().unwrap_or(id).to_string();
            vm_alias_map.insert(id.clone(), alias);
        }
    }

    svc_map
        .iter()
        .map(|(name, svc)| {
            let vm_id = svc["vm"].as_str().unwrap_or("").to_string();
            let vm_alias = vm_alias_map
                .get(&vm_id)
                .cloned()
                .unwrap_or_else(|| vm_id.clone());

            let containers: Vec<ContainerDecl> = svc["containers"]
                .as_object()
                .unwrap_or(&empty_map)
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
        .collect()
}

/// Parse caddy routes from caddy routes JSON
pub fn parse_caddy_routes(caddy_json: &Value) -> Vec<CaddyRoute> {
    caddy_json["routes"]
        .as_array()
        .map(|routes| {
            routes
                .iter()
                .map(|r| CaddyRoute {
                    domain: r["domain"].as_str().unwrap_or("").to_string(),
                    upstream: r["upstream"].as_str().unwrap_or("").to_string(),
                    comment: r["comment"].as_str().unwrap_or("").to_string(),
                    auth: r["auth"].as_str().map(|s| s.to_string()),
                    // build-caddy.json omits the key entirely for public
                    // routes (see cloud-data-config-derive.ts) — absent
                    // means false in this already-derived file.
                    wg_only: r["wg_only"].as_bool().unwrap_or(false),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Scan build.json files for ports.app
pub fn scan_build_json_ports(base: &str) -> HashMap<String, u16> {
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

        let folder_name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let svc_name = j["name"]
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                folder_name
                    .split('_')
                    .skip(1)
                    .collect::<Vec<_>>()
                    .join("_")
            });

        if let Some(port) = j["ports"]["app"].as_u64() {
            ports.insert(svc_name, port as u16);
        }
    }
    ports
}
