use super::types::*;
use anyhow::{Context as _, Result};
use reports_common::caddy;
use reports_common::context::find_cloud_data_file;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// R4: infer the mail protocol label for an L4 route from its SNI / upstream
/// port. Data-shape only — no hardcoded host list.
fn mail_l4_proto(r: &reports_common::caddy::L4Port) -> String {
    if r.port == 25 {
        return "SMTP-MX".into();
    }
    let sni = r.sni.as_deref().unwrap_or("").to_ascii_lowercase();
    let up_port = r.upstream.rsplit(':').next().and_then(|p| p.parse::<u16>().ok());
    if sni.starts_with("imap") || matches!(up_port, Some(993) | Some(2993)) {
        "IMAPS".into()
    } else if sni.starts_with("jmap") || matches!(up_port, Some(2443)) {
        "JMAP".into()
    } else if sni.starts_with("smtp") || matches!(up_port, Some(465) | Some(2465)) {
        "SMTPS".into()
    } else if sni.starts_with("mail") {
        "HTTPS".into()
    } else {
        "TCP".into()
    }
}

pub fn load_context() -> Result<Context> {
    let path = find_cloud_data_file("_cloud-data-consolidated.json")
        .context("_cloud-data-consolidated.json not found (walked up from cwd)")?;
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("reading {}", path.display()))?;
    let c: Value = serde_json::from_str(&raw)?;

    let mut vm_alias_map: HashMap<String, String> = HashMap::new();
    let mut host_ports_by_vm: HashMap<String, HashSet<u16>> = HashMap::new();

    // VMs
    let vms: Vec<VmInfo> = c["vms"].as_object().unwrap_or(&serde_json::Map::new()).iter().map(|(id, vm)| {
        let alias = vm["ssh_alias"].as_str().unwrap_or(id).to_string();
        vm_alias_map.insert(id.clone(), alias.clone());
        // Host ports
        let mut ports = HashSet::new();
        if let Some(pp) = vm["public_ports"].as_array() {
            for p in pp { if let Some(port) = p["port"].as_u64() { ports.insert(port as u16); } }
        }
        let mut declared_ports: Vec<u16> = ports.iter().copied().collect();
        host_ports_by_vm.insert(alias.clone(), ports);

        let provider = if id.starts_with("oci-") { "OCI" } else if id.starts_with("gcp-") { "GCP" } else if id.starts_with("vast-") { "Vast.ai" } else { "?" };
        let cost = if id.contains("-f_") || id.contains("-f-") { "Free" } else if id.contains("-p_") { "Spot" } else { "?" };
        declared_ports.sort();
        VmInfo {
            alias, vm_id: id.clone(),
            pub_ip: vm["ip"].as_str().unwrap_or("?").to_string(),
            wg_ip: vm["wg_ip"].as_str().unwrap_or("?").to_string(),
            cloud_name: vm["specs"]["cloud_name"].as_str().unwrap_or("—").to_string(),
            cloud_zone: vm["specs"]["cloud_zone"].as_str().unwrap_or("?").to_string(),
            rescue_port: vm["rescue_port"].as_u64().unwrap_or(2200) as u16,
            cpus: vm["specs"]["cpu"].as_u64().unwrap_or(0) as u32,
            ram_gb: format!("{}G", vm["specs"]["ram_gb"].as_u64().unwrap_or(0)),
            disk_gb: format!("{}G", vm["specs"]["disk_gb"].as_u64().unwrap_or(0)),
            shape: vm["specs"]["shape"].as_str().or(vm["specs"]["machine_type"].as_str()).unwrap_or("?").to_string(),
            provider: provider.to_string(),
            cost: cost.to_string(),
            declared_ports,
        }
    }).filter(|v| !v.wg_ip.is_empty() && v.wg_ip != "?").collect();

    // Public URLs — source of truth is build-caddy.json (routes + public_A_mcp +
    // public_B_apis + public_C_app_paths + public_D_others). Deduplicated by
    // hostname — downstream probes prepend `https://` to the bare domain so we
    // cover the edge once per hostname. Services with a `.domain` declared in
    // their build.json but not (yet) wired into Caddy still get probed so we
    // surface drift.
    let mut public_urls: Vec<UrlInfo> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut add = |urls: &mut Vec<UrlInfo>, seen: &mut HashSet<String>, host: String, upstream: String| {
        if !seen.contains(&host) { seen.insert(host.clone()); urls.push(UrlInfo { url: host, upstream }); }
    };

    for t in caddy::load_public_targets() {
        add(&mut public_urls, &mut seen, t.host.clone(), t.upstream.clone());
    }
    for (_, svc) in c["services"].as_object().unwrap_or(&serde_json::Map::new()) {
        if let Some(domain) = svc["domain"].as_str() {
            let upstream = svc["upstream"].as_str().unwrap_or("?");
            let host = domain.trim_start_matches("https://").trim_start_matches("http://")
                .split('/').next().unwrap_or(domain).to_string();
            add(&mut public_urls, &mut seen, host, upstream.to_string());
        }
    }

    // Private DNS — source of truth is build-caddy.json
    // (`private_A1_app_canonical` + `private_B0_db`). Falls back to
    // services.containers for entries missing from the catalog.
    let mut private_dns: Vec<DnsEntry> = Vec::new();
    let mut private_seen: HashSet<(String, u16)> = HashSet::new();

    let split_upstream = |s: &str| -> Option<(String, u16)> {
        let stripped = s.strip_prefix("http://").or_else(|| s.strip_prefix("https://")).unwrap_or(s);
        let mut parts = stripped.rsplitn(2, ':');
        let port: u16 = parts.next()?.trim_end_matches('/').parse().ok()?;
        let host = parts.next()?;
        if host.is_empty() || port == 0 { return None; }
        Some((host.to_string(), port))
    };

    for t in caddy::load_private_app_targets().into_iter().chain(caddy::load_private_db_targets().into_iter()) {
        let Some((upstream_ip, port)) = split_upstream(&t.upstream) else { continue };
        let vm = vm_alias_map.values()
            .find(|alias| {
                // Match upstream ip back to vm via wg_ip.
                c["vms"].as_object().map(|vms| vms.iter().any(|(_, v)| v["wg_ip"].as_str() == Some(&upstream_ip) && v["ssh_alias"].as_str() == Some(alias))).unwrap_or(false)
            }).cloned().unwrap_or_default();
        let host_port = host_ports_by_vm.get(&vm).map(|s| s.contains(&port)).unwrap_or(false);
        if private_seen.insert((t.host.clone(), port)) {
            private_dns.push(DnsEntry {
                dns: t.host.clone(),
                container: t.service.unwrap_or_else(|| "?".into()),
                port, vm, host_port,
            });
        }
    }
    // Fill in any container-declared DNS not present in the caddy catalog (drift).
    for (_, svc) in c["services"].as_object().unwrap_or(&serde_json::Map::new()) {
        let vm_alias = vm_alias_map.get(svc["vm"].as_str().unwrap_or("")).cloned().unwrap_or_default();
        for (_, ct) in svc["containers"].as_object().unwrap_or(&serde_json::Map::new()) {
            let dns = ct["dns"].as_str().unwrap_or("").to_string();
            let port = ct["port"].as_u64().unwrap_or(0) as u16;
            if dns.is_empty() || port == 0 { continue; }
            if !private_seen.insert((dns.clone(), port)) { continue; }
            let host_port = host_ports_by_vm.get(&vm_alias).map(|s| s.contains(&port)).unwrap_or(false);
            private_dns.push(DnsEntry {
                dns, container: ct["container_name"].as_str().unwrap_or("?").to_string(),
                port, vm: vm_alias.clone(), host_port,
            });
        }
    }
    private_dns.sort_by(|a, b| a.vm.cmp(&b.vm).then(a.dns.cmp(&b.dns)));

    // Databases — migrated to build-reports.json:.databases (single derived file).
    // Legacy cloud-data-databases.json fallback during migration window.
    let mut databases: Vec<DbEntry> = Vec::new();
    let db_value: Option<Value> = reports_common::context::load_build_reports_section("databases")
        .map(|v| serde_json::json!({"databases": v}))
        .or_else(|| {
            find_cloud_data_file("cloud-data-databases.json")
                .and_then(|p| std::fs::read_to_string(p).ok())
                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        });
    if let Some(db_json) = db_value {
        {
            for db in db_json["databases"].as_array().unwrap_or(&vec![]) {
                let container = db["container"].as_str().unwrap_or("?").to_string();
                let db_type = db["type"].as_str().unwrap_or("?").to_string();
                let vm_alias = db["vm_alias"].as_str().unwrap_or("").to_string();
                let port = db["port"].as_u64().unwrap_or(0) as u16;
                let dns = db["dns"].as_str().unwrap_or("").to_string();
                let dns_access = if dns.is_empty() { "embedded".to_string() } else if port > 0 { format!("{}:{}", dns, port) } else { dns.clone() };
                databases.push(DbEntry {
                    service: db["service"].as_str().unwrap_or("?").to_string(),
                    db_type,
                    container,
                    db_name: db["db"].as_str().or(db["path"].as_str()).unwrap_or("custom").to_string(),
                    db_user: db["user"].as_str().unwrap_or("").to_string(),
                    port,
                    vm: vm_alias,
                    dns_access,
                    enabled: db["enabled"].as_bool().unwrap_or(true),
                    healthcheck: db["healthcheck"].as_str().unwrap_or("").to_string(),
                    backup: db["backup"].as_bool().unwrap_or(false),
                });
            }
        }
    }
    databases.sort_by(|a, b| a.vm.cmp(&b.vm).then(a.service.cmp(&b.service)));

    // WG peers
    let wg = &c["native"]["wireguard"];
    let mut wg_peers: Vec<WgPeer> = Vec::new();
    for peer in wg["peers"].as_array().unwrap_or(&vec![]) {
        wg_peers.push(WgPeer {
            name: peer["name"].as_str().unwrap_or("?").to_string(),
            wg_ip: peer["wg_ip"].as_str().unwrap_or("?").to_string(),
            pub_ip: peer["endpoint"].as_str().unwrap_or("?").split(':').next().unwrap_or("?").to_string(),
            role: peer["role"].as_str().unwrap_or("spoke").to_string(),
        });
    }
    for (name, client) in wg["clients"].as_object().unwrap_or(&serde_json::Map::new()) {
        wg_peers.push(WgPeer {
            name: name.clone(),
            wg_ip: client["wg_ip"].as_str().unwrap_or("?").to_string(),
            pub_ip: "dynamic".to_string(),
            role: "client".to_string(),
        });
    }

    // Mail ports — R4: data-driven from build-caddy.json L4 SNI map (the SoT
    // for mail-client listeners). Each L4 mail route → a MailPort using the
    // SNI hostname (or the upstream host for the non-SNI :25 MX), the public
    // listener port, and a protocol inferred from the SNI/upstream port.
    let mail_ports: Vec<MailPort> = caddy::load_l4_mail_ports()
        .into_iter()
        .map(|r| {
            let host = r
                .sni
                .clone()
                .unwrap_or_else(|| r.upstream.split(':').next().unwrap_or("mail").to_string());
            let proto = mail_l4_proto(&r);
            MailPort { host, port: r.port, proto }
        })
        .collect();

    // Caddy L4
    let caddy_l4: Vec<L4Route> = c["configs"]["caddy"]["l4_routes"].as_array().unwrap_or(&vec![]).iter().map(|r| {
        L4Route {
            port: r["port"].as_u64().unwrap_or(0) as u16,
            upstream: r["upstream"].as_str().unwrap_or("?").to_string(),
            comment: r["comment"].as_str().unwrap_or("").to_string(),
        }
    }).collect();

    // Bearer token
    let home = std::env::var("HOME").unwrap_or("/home/diego".into());
    let bearer_token = std::fs::read_to_string(format!("{}/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json", home))
        .ok().and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v["access_token"].as_str().map(|s| s.to_string()));

    Ok(Context { consolidated: c, vms, public_urls, private_dns, databases, wg_peers, mail_ports, caddy_l4, bearer_token })
}
