use crate::types::*;
use std::fmt::Write;

/// Sanitize VM name for Mermaid node IDs (replace hyphens with underscores)
fn node_id(name: &str) -> String {
    name.replace('-', "_").replace(' ', "_")
}

const DARK_INIT: &str = r#"%%{init: {'theme': 'dark'}}%%"#;

// ── 1. Container Distribution ──────────────────────────────────────

pub fn containers(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    let active: Vec<&VmData> = data.vms.iter().filter(|v| v.containers_total > 0).collect();
    if active.is_empty() {
        return s;
    }

    // Define nodes
    for vm in &active {
        let id = node_id(&vm.name);
        writeln!(
            s,
            r#"  {}["{}<br/>{}/{} ctrs"]"#,
            id, vm.name, vm.containers_running, vm.containers_total
        )
        .unwrap();
    }

    // Connect first VM to all others (hub-spoke from proxy)
    let hub = active
        .iter()
        .find(|v| v.name.contains("proxy") || v.name.contains("gcp"))
        .or(active.first());
    if let Some(hub_vm) = hub {
        let hub_id = node_id(&hub_vm.name);
        for vm in &active {
            if vm.name != hub_vm.name {
                writeln!(s, "  {} --- {}", hub_id, node_id(&vm.name)).unwrap();
            }
        }
    }

    s
}

// ── 2. Data Storage ────────────────────────────────────────────────

pub fn data_storage(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph TD").unwrap();

    let bucket_count = data.cloud_buckets.len();
    let total_vols: usize = data.vms.iter().map(|v| v.runtime_volumes.len()).sum();
    let db_count = data.databases.iter().filter(|d| d.enabled).count();

    writeln!(
        s,
        r#"  buckets["OCI Buckets<br/>{} buckets"] --> backups["Backups"]"#,
        bucket_count
    )
    .unwrap();
    writeln!(
        s,
        r#"  vms["VMs"] --> volumes["Docker Volumes<br/>{}"]"#,
        total_vols
    )
    .unwrap();
    writeln!(
        s,
        r#"  volumes --> dbs["Databases<br/>{}"]"#,
        db_count
    )
    .unwrap();
    writeln!(
        s,
        r#"  ghcr["GHCR<br/>{} images"] --> vms"#,
        data.ghcr_total
    )
    .unwrap();

    s
}

// ── 3. Security Layers ─────────────────────────────────────────────

pub fn security_layers(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph TD").unwrap();

    let certs_ok = data.certs.iter().filter(|c| c.days_left >= 7).count();
    let certs_total = data.certs.len();
    let endpoints_ok = data
        .endpoints
        .iter()
        .filter(|e| (200..=399).contains(&e.status_code))
        .count();

    writeln!(
        s,
        r#"  cf["Cloudflare<br/>DDoS + CDN"] --> caddy["Caddy<br/>TLS + {}/{} certs"]"#,
        certs_ok, certs_total
    )
    .unwrap();
    writeln!(
        s,
        r#"  caddy --> auth["Authelia<br/>2FA / OIDC<br/>{}/{} OK"]"#,
        endpoints_ok,
        data.endpoints.len()
    )
    .unwrap();
    writeln!(
        s,
        r#"  auth --> introspect["introspect-proxy<br/>Bearer tokens"]"#
    )
    .unwrap();
    writeln!(
        s,
        r#"  introspect --> container["Container<br/>{} isolated"]"#,
        data.fleet_running
    )
    .unwrap();

    s
}

// ── 4. CI/CD Pipeline ──────────────────────────────────────────────

pub fn cicd_pipeline(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    let gha_count = data.gha_runs.len();
    let gha_ok = data
        .gha_runs
        .iter()
        .filter(|r| r.conclusion == "success")
        .count();
    let dag_count = data.dags.len();

    writeln!(s, r#"  dev["Developer"] --> github["GitHub<br/>{} repos"]"#, data.repos.len()).unwrap();
    writeln!(s, r#"  github --> gha["GHA<br/>{}/{} OK"]"#, gha_ok, gha_count).unwrap();
    writeln!(s, r#"  gha --> ghcr["GHCR<br/>{} images"]"#, data.ghcr_total).unwrap();
    writeln!(s, r#"  ghcr --> vms["VMs<br/>{}"]"#, data.vms.len()).unwrap();
    writeln!(s, r#"  github --> gendata["cloud-data-config"]"#).unwrap();
    writeln!(s, r#"  gendata --> dagu["Dagu<br/>{} DAGs"]"#, dag_count).unwrap();
    writeln!(s, r#"  dagu --> vms"#).unwrap();

    s
}

// ── 5. Service Routing ─────────────────────────────────────────────

pub fn service_routing(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    writeln!(
        s,
        r#"  domains["*.diegonmarcos.com<br/>{} domains"] --> cf["Cloudflare"]"#,
        data.total_domains
    )
    .unwrap();
    writeln!(
        s,
        r#"  cf --> caddy["Caddy<br/>{} routes"]"#,
        data.endpoints.len()
    )
    .unwrap();
    writeln!(
        s,
        r#"  caddy --> wg["WireGuard<br/>{} VMs"]"#,
        data.vms.len()
    )
    .unwrap();
    writeln!(
        s,
        r#"  wg --> containers["Containers<br/>{} services"]"#,
        data.total_services
    )
    .unwrap();

    s
}

// ── 6. VM Resources ────────────────────────────────────────────────

pub fn vm_resources(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    if data.vm_finops.is_empty() {
        return s;
    }

    let mut sorted: Vec<&VmFinops> = data.vm_finops.iter().collect();
    sorted.sort_by(|a, b| {
        let sa = a.cpu as f64 * a.ram_gb;
        let sb = b.cpu as f64 * b.ram_gb;
        sb.partial_cmp(&sa).unwrap_or(std::cmp::Ordering::Equal)
    });

    for vm in &sorted {
        let id = node_id(&vm.alias);
        let tier_label = if vm.tier == "Free" { "FREE" } else { "PAID" };
        writeln!(
            s,
            r#"  {}["{}<br/>{}cpu / {}GB<br/>{}"]"#,
            id, vm.alias, vm.cpu, vm.ram_gb, tier_label
        )
        .unwrap();
    }

    // Connect all to a central infra node
    writeln!(s, r#"  infra(("Infrastructure"))"#).unwrap();
    for vm in &sorted {
        writeln!(s, "  infra --- {}", node_id(&vm.alias)).unwrap();
    }

    s
}

// ── 7. AI Models ───────────────────────────────────────────────────

pub fn ai_models(data: &ReportData) -> String {
    let Some(ai) = &data.ai else {
        return String::new();
    };
    if ai.models.is_empty() || ai.total_cost_usd <= 0.0 {
        return String::new();
    }

    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    writeln!(
        s,
        r#"  claude["Claude Code<br/>${:.2} total"]"#,
        ai.total_cost_usd
    )
    .unwrap();

    for m in &ai.models {
        let id = node_id(&m.model);
        writeln!(
            s,
            r#"  claude --> {}["{}<br/>${:.2}"]"#,
            id, m.model, m.estimated_cost_usd
        )
        .unwrap();
    }

    s
}

// ── 8. WireGuard Mesh ──────────────────────────────────────────────

pub fn wireguard_mesh(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph TD").unwrap();

    // Find hub (gcp-proxy)
    let hub = data.vms.iter().find(|v| v.name.contains("proxy") || v.name == "gcp-proxy");
    let hub_ip = hub.map(|h| h.ip.as_str()).unwrap_or("10.0.0.1");
    let hub_ctrs = hub.map(|h| h.containers_running).unwrap_or(0);

    writeln!(
        s,
        r#"  gcp_proxy["{}<br/>{}<br/>HUB<br/>{} ctrs"]"#,
        "gcp-proxy", hub_ip, hub_ctrs
    )
    .unwrap();

    // Static non-VM nodes
    writeln!(s, r#"  surface["Surface<br/>10.0.0.2"]"#).unwrap();
    writeln!(s, r#"  termux["Termux<br/>10.0.0.9"]"#).unwrap();

    // Dynamic VM nodes (excluding hub)
    for vm in &data.vms {
        if vm.name.contains("proxy") || vm.name == "gcp-proxy" {
            continue;
        }
        let id = node_id(&vm.name);
        writeln!(
            s,
            r#"  {}["{}<br/>{}<br/>{} ctrs"]"#,
            id, vm.name, vm.ip, vm.containers_running
        )
        .unwrap();
    }

    // Connect all to hub
    writeln!(s, "  surface --- gcp_proxy").unwrap();
    writeln!(s, "  termux --- gcp_proxy").unwrap();
    for vm in &data.vms {
        if vm.name.contains("proxy") || vm.name == "gcp-proxy" {
            continue;
        }
        writeln!(s, "  gcp_proxy --- {}", node_id(&vm.name)).unwrap();
    }

    s
}

// ── 9. Traffic Flow ────────────────────────────────────────────────

pub fn traffic_flow(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    let caddy_ip = data
        .vms
        .iter()
        .find(|v| v.name == "gcp-proxy")
        .map(|v| v.ip.as_str())
        .unwrap_or("10.0.0.1");

    writeln!(s, r#"  user["User<br/>browser/CLI"]"#).unwrap();
    writeln!(s, r#"  cf["Cloudflare<br/>DNS + WAF"]"#).unwrap();
    writeln!(s, r#"  caddy["Caddy<br/>:443 | {}"]"#, caddy_ip).unwrap();
    writeln!(s, r#"  wg["WireGuard<br/>10.0.0.0/24"]"#).unwrap();
    writeln!(s, r#"  vm["VM<br/>{} nodes"]"#, data.vms.len()).unwrap();
    writeln!(
        s,
        r#"  ctr["Container<br/>{}/{}"]"#,
        data.fleet_running, data.fleet_total
    )
    .unwrap();

    writeln!(s, "  user --> cf --> caddy --> wg --> vm --> ctr").unwrap();

    s
}

// ── 10. Service Categories (Pie Chart) ─────────────────────────────

pub fn service_categories(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "pie title Service Categories").unwrap();

    let mut map: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for svc in data.services.iter().filter(|sv| sv.enabled) {
        *map.entry(svc.category.clone()).or_default() += 1;
    }

    let mut sorted: Vec<_> = map.into_iter().collect();
    sorted.sort_by(|a, b| b.1.cmp(&a.1));

    for (cat, count) in sorted {
        writeln!(s, r#"  "{}" : {}"#, cat, count).unwrap();
    }

    s
}

// ── 11. Storage Overview ───────────────────────────────────────────

pub fn storage_overview(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    let total_vols: usize = data.vms.iter().map(|v| v.runtime_volumes.len()).sum();
    let db_count = data.databases.iter().filter(|d| d.enabled).count();

    let ghcr_disk = if data.github_disk_kb > 1_048_576 {
        format!("{:.1}GB", data.github_disk_kb as f64 / 1_048_576.0)
    } else if data.github_disk_kb > 1024 {
        format!("{:.0}MB", data.github_disk_kb as f64 / 1024.0)
    } else if data.github_disk_kb > 0 {
        format!("{}KB", data.github_disk_kb)
    } else {
        "?".into()
    };

    writeln!(
        s,
        r#"  oci_s3["OCI S3<br/>{} buckets"] --> ghcr["GHCR<br/>{} imgs, {}"]"#,
        data.cloud_buckets.len(),
        data.ghcr_total,
        ghcr_disk
    )
    .unwrap();
    writeln!(
        s,
        r#"  ghcr --> volumes["Volumes<br/>{} vols"]"#,
        total_vols
    )
    .unwrap();
    writeln!(
        s,
        r#"  volumes --> dbs["DBs<br/>{} declared"]"#,
        db_count
    )
    .unwrap();

    s
}

// ── 12. Network Zones ─────────────────────────────────────────────

pub fn network_zones(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph LR").unwrap();

    let vm_count = data.vms.len();
    let container_count = data.fleet_running;

    writeln!(s, r#"  internet["Internet"]"#).unwrap();
    writeln!(s, r#"  dmz["DMZ<br/>gcp-proxy"]"#).unwrap();
    writeln!(s, r#"  wg["WireGuard<br/>Mesh"]"#).unwrap();
    writeln!(s, r#"  private["Private<br/>{} VMs"]"#, vm_count).unwrap();
    writeln!(s, r#"  containers["Containers<br/>{} running"]"#, container_count).unwrap();

    writeln!(s, "  internet --> dmz --> wg --> private --> containers").unwrap();

    s
}

// ── 13. Provider Map ───────────────────────────────────────────────

pub fn provider_map(data: &ReportData) -> String {
    let mut s = String::new();
    writeln!(s, "{}", DARK_INIT).unwrap();
    writeln!(s, "graph TD").unwrap();

    if data.vm_finops.is_empty() {
        return s;
    }

    // Group VMs by provider
    let mut groups: std::collections::BTreeMap<String, Vec<&VmFinops>> =
        std::collections::BTreeMap::new();
    for vm in &data.vm_finops {
        groups.entry(vm.provider.clone()).or_default().push(vm);
    }

    for (provider, vms) in &groups {
        let provider_id = node_id(provider);
        writeln!(s, "  subgraph {} [{}]", provider_id, provider).unwrap();
        for vm in vms {
            let id = node_id(&vm.alias);
            let tier_label = if vm.tier == "Free" { "FREE" } else { "PAID" };
            writeln!(
                s,
                r#"    {}["{}<br/>{}cpu/{}GB<br/>{}"]"#,
                id, vm.alias, vm.cpu, vm.ram_gb, tier_label
            )
            .unwrap();
        }
        writeln!(s, "  end").unwrap();
    }

    // Connect providers together
    let provider_ids: Vec<String> = groups.keys().map(|p| node_id(p)).collect();
    for window in provider_ids.windows(2) {
        writeln!(s, "  {} --- {}", window[0], window[1]).unwrap();
    }

    s
}
