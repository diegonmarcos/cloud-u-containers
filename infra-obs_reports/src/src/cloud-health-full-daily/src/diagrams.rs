use crate::types::*;
use std::fmt::Write;
use std::process::Command;

// ── Core renderer ──────────────────────────────────────────────────

/// Render a diagram source to SVG using an external tool.
/// Returns SVG string or empty string if tool not available.
fn render_svg(tool: &str, args: &[&str], input: &str) -> String {
    let output = Command::new(tool)
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn();

    match output {
        Ok(mut child) => {
            use std::io::Write;
            if let Some(mut stdin) = child.stdin.take() {
                stdin.write_all(input.as_bytes()).ok();
            }
            match child.wait_with_output() {
                Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
                Ok(o) => {
                    let stderr = String::from_utf8_lossy(&o.stderr);
                    eprintln!("  diagram tool '{}' failed: {}", tool, stderr.trim());
                    String::new()
                }
                Err(e) => {
                    eprintln!("  diagram tool '{}' wait error: {}", tool, e);
                    String::new()
                }
            }
        }
        Err(_) => {
            eprintln!("  diagram tool '{}' not available", tool);
            String::new()
        }
    }
}

fn dot_svg(input: &str) -> String {
    render_svg("dot", &["-Tsvg"], input)
}

fn d2_svg(input: &str) -> String {
    render_svg("d2", &["-", "-", "--theme", "200", "--pad", "10", "--layout", "elk"], input)
}

fn plantuml_svg(input: &str) -> String {
    render_svg("plantuml", &["-tsvg", "-pipe"], input)
}

fn pikchr_svg(input: &str) -> String {
    render_svg("pikchr", &["--svg-only", "-"], input)
}

/// Sanitize a name for use as a Graphviz node ID
fn gv_id(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect()
}

// Color constants for diagram sources
const D_BG: &str = "#1a1a2e";
const D_CARD: &str = "#16213e";
const D_HEAD: &str = "#0f3460";
const D_OK: &str = "#00d68f";
const D_WARN: &str = "#ffaa00";
const D_CRIT: &str = "#ff3d71";
const D_TEXT: &str = "#e0e0e0";
const D_DIM: &str = "#8899aa";

// ── 1. WireGuard Mesh (Graphviz) ───────────────────────────────────

pub fn wireguard_mesh_dot(data: &ReportData) -> String {
    let mut src = String::new();
    writeln!(src, "digraph WG {{").unwrap();
    writeln!(src, "  bgcolor=\"{}\";", D_BG).unwrap();
    writeln!(src, "  node [style=filled,fillcolor=\"{}\",fontcolor=\"{}\",color=\"{}\",fontname=\"Courier\",fontsize=10];",
        D_CARD, D_TEXT, D_OK).unwrap();
    writeln!(src, "  edge [color=\"{}\"];", D_OK).unwrap();

    // Find hub
    let hub = data.vms.iter().find(|v| v.name.contains("proxy") || v.name == "gcp-proxy");
    let hub_name = hub.map(|h| h.name.as_str()).unwrap_or("gcp-proxy");
    let hub_ip = hub.map(|h| h.ip.as_str()).unwrap_or("10.0.0.1");
    let hub_ctrs = hub.map(|h| h.containers_running).unwrap_or(0);

    writeln!(src, "  {} [label=\"{}\\n{}\\nHUB\\n{} ctrs\",shape=doubleoctagon,fillcolor=\"{}\"];",
        gv_id(hub_name), hub_name, hub_ip, hub_ctrs, D_HEAD).unwrap();

    // Static non-VM peers
    writeln!(src, "  surface [label=\"Surface\\n10.0.0.2\",shape=box];").unwrap();
    writeln!(src, "  termux [label=\"Termux\\n10.0.0.9\",shape=box];").unwrap();

    // Dynamic VM nodes
    for vm in &data.vms {
        if vm.name == hub_name { continue; }
        let id = gv_id(&vm.name);
        writeln!(src, "  {} [label=\"{}\\n{}\\n{} ctrs\"];",
            id, vm.name, vm.ip, vm.containers_running).unwrap();
    }

    // Edges: hub-spoke
    let hub_id = gv_id(hub_name);
    writeln!(src, "  surface -> {} [dir=both];", hub_id).unwrap();
    writeln!(src, "  termux -> {} [dir=both];", hub_id).unwrap();
    for vm in &data.vms {
        if vm.name == hub_name { continue; }
        writeln!(src, "  {} -> {} [dir=both];", hub_id, gv_id(&vm.name)).unwrap();
    }

    writeln!(src, "}}").unwrap();
    dot_svg(&src)
}

// ── 2. Security Layers (D2) ───────────────────────────────────────

pub fn security_layers_d2(data: &ReportData) -> String {
    let certs_ok = data.certs.iter().filter(|c| c.days_left >= 7).count();
    let certs_total = data.certs.len();
    let wg_peers: usize = data.vms.iter().map(|v| v.wg_peers.len()).sum();
    let wg_only_count = data.firewalls.iter().filter(|f| f.wg_only).count();
    let dns_ok = data.dns.iter().filter(|d| !d.value.is_empty()).count();

    let mut src = String::new();
    writeln!(src, "direction: right").unwrap();

    // Row 1: External → Edge
    writeln!(src, "cloud_fw: \"Cloud Firewalls\\nOCI + GCP rules\" {{ shape: hexagon; style.fill: \"{}\"; style.font-color: \"{}\" }}", D_HEAD, D_TEXT).unwrap();
    writeln!(src, "cloudflare: \"Cloudflare\\nDDoS + CDN + DNS\" {{ shape: cloud; style.fill: \"{}\"; style.font-color: \"{}\" }}", D_HEAD, D_TEXT).unwrap();

    // Row 2: Network encryption
    writeln!(src, "wireguard: \"WireGuard VPN\\n10.0.0.0/24\\n{} peers\\n{} VMs WG-only\" {{ shape: cylinder; style.fill: \"{}\"; style.font-color: \"{}\"; style.stroke: \"{}\" }}",
        wg_peers, wg_only_count, D_CARD, D_TEXT, "#57A6D6").unwrap();

    // Row 3: Application auth
    writeln!(src, "caddy: \"Caddy\\nTLS termination\\n{}/{} certs\" {{ shape: hexagon; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        certs_ok, certs_total, D_CARD, D_TEXT).unwrap();
    writeln!(src, "authelia: \"Authelia\\n2FA TOTP/WebAuthn\\nOIDC Provider\" {{ shape: diamond; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        D_CARD, D_TEXT).unwrap();
    writeln!(src, "introspect: \"introspect-proxy\\nBearer token validation\" {{ shape: hexagon; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        D_CARD, D_TEXT).unwrap();

    // Row 4: Container isolation + secrets
    writeln!(src, "docker: \"Docker Isolation\\ncgroups + namespaces\\n{} containers\" {{ shape: rectangle; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        data.fleet_running, D_CARD, D_TEXT).unwrap();
    writeln!(src, "sops: \"SOPS\\nage encryption\\nsecrets at rest\" {{ shape: page; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        D_CARD, D_TEXT).unwrap();

    // Row 5: Email security
    writeln!(src, "email: \"Email Security\\nDKIM + SPF + DMARC\\n{}/4 DNS OK\" {{ shape: page; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        dns_ok, D_CARD, D_TEXT).unwrap();

    // Connections
    writeln!(src, "cloud_fw -> wireguard: \"encrypted tunnel\"").unwrap();
    writeln!(src, "cloudflare -> caddy: \"HTTPS\"").unwrap();
    writeln!(src, "wireguard -> caddy: \"mesh traffic\"").unwrap();
    writeln!(src, "caddy -> authelia: \"forward_auth\"").unwrap();
    writeln!(src, "authelia -> introspect: \"OIDC token\"").unwrap();
    writeln!(src, "introspect -> docker: \"validated request\"").unwrap();
    writeln!(src, "docker -> sops: \"reads secrets\"").unwrap();
    writeln!(src, "caddy -> email: \"mail routing\"").unwrap();

    d2_svg(&src)
}

// ── 3. Data Flow (PlantUML) ───────────────────────────────────────

pub fn data_flow_plantuml(data: &ReportData) -> String {
    let bucket_count = data.cloud_buckets.len();
    let total_vols: usize = data.vms.iter().map(|v| v.runtime_volumes.len()).sum();
    let db_count = data.databases.iter().filter(|d| d.enabled).count();

    let mut src = String::new();
    writeln!(src, "@startuml").unwrap();
    writeln!(src, "skinparam backgroundColor {}", D_BG).unwrap();
    writeln!(src, "skinparam defaultFontColor {}", D_TEXT).unwrap();
    writeln!(src, "skinparam defaultFontName Courier").unwrap();
    writeln!(src, "skinparam component {{").unwrap();
    writeln!(src, "  BackgroundColor {}", D_CARD).unwrap();
    writeln!(src, "  BorderColor {}", D_OK).unwrap();
    writeln!(src, "  FontColor {}", D_TEXT).unwrap();
    writeln!(src, "}}").unwrap();
    writeln!(src, "skinparam database {{").unwrap();
    writeln!(src, "  BackgroundColor {}", D_CARD).unwrap();
    writeln!(src, "  BorderColor {}", D_OK).unwrap();
    writeln!(src, "  FontColor {}", D_TEXT).unwrap();
    writeln!(src, "}}").unwrap();
    writeln!(src, "skinparam ArrowColor {}", D_OK).unwrap();
    writeln!(src, "component \"OCI Buckets\\n{} buckets\" as buckets", bucket_count).unwrap();
    writeln!(src, "component \"Docker Volumes\\n{}\" as volumes", total_vols).unwrap();
    writeln!(src, "database \"Databases\\n{}\" as dbs", db_count).unwrap();
    writeln!(src, "component \"GHCR\\n{} images\" as ghcr", data.ghcr_total).unwrap();
    writeln!(src, "buckets <-- volumes : backup").unwrap();
    writeln!(src, "ghcr --> volumes : pull").unwrap();
    writeln!(src, "volumes --> dbs").unwrap();
    writeln!(src, "@enduml").unwrap();

    plantuml_svg(&src)
}

// ── 4. DNS Chain (Pikchr) ─────────────────────────────────────────

pub fn dns_chain_pikchr(data: &ReportData) -> String {
    let _ = data; // diagram uses static topology

    let mut src = String::new();
    writeln!(src, "box \"User\" fit").unwrap();
    writeln!(src, "arrow right 100%").unwrap();
    writeln!(src, "box \"Cloudflare\" \"DNS Proxy\" fit color green").unwrap();
    writeln!(src, "arrow right 100%").unwrap();
    writeln!(src, "box \"Hickory DNS\" \"10.0.0.1:53\" fit").unwrap();
    writeln!(src, "arrow right 100%").unwrap();
    writeln!(src, "box \"*.app zones\" \"(internal)\" fit color blue").unwrap();

    pikchr_svg(&src)
}

// ── 5. Container Distribution (Graphviz) ──────────────────────────

pub fn container_distribution_dot(data: &ReportData) -> String {
    let total_ctrs = data.vms.iter().map(|v| v.containers_running).sum::<u32>();
    let total_declared = data.vms.iter().map(|v| v.containers_total).sum::<u32>();

    let mut src = String::new();
    writeln!(src, "digraph ContainerFlow {{").unwrap();
    writeln!(src, "  bgcolor=\"{}\";", D_BG).unwrap();
    writeln!(src, "  rankdir=LR;").unwrap();
    writeln!(src, "  node [style=filled,fillcolor=\"{}\",fontcolor=\"{}\",color=\"{}\",fontname=\"Courier\",fontsize=10,shape=box];",
        D_CARD, D_TEXT, D_OK).unwrap();
    writeln!(src, "  edge [color=\"{}\",fontcolor=\"{}\",fontsize=9,fontname=\"Courier\"];", D_OK, D_DIM).unwrap();
    writeln!(src, "  newrank=true;").unwrap();

    // ── PUBLIC PATH (top) ──
    writeln!(src, "  subgraph cluster_public {{").unwrap();
    writeln!(src, "    label=\"PUBLIC PATH\"; style=dashed; color=\"{}\"; fontcolor=\"{}\"; fontsize=11;", D_OK, D_OK).unwrap();
    writeln!(src, "    internet [label=\"Internet\",shape=ellipse,fillcolor=\"{}\"];", D_HEAD).unwrap();
    writeln!(src, "    cloudflare [label=\"Cloudflare\\nDNS + CDN\",shape=ellipse,fillcolor=\"{}\"];", D_HEAD).unwrap();
    writeln!(src, "    caddy_pub [label=\"Caddy :443\\ngcp-proxy\\n{} routes\",shape=hexagon];",
        data.endpoints.len()).unwrap();
    writeln!(src, "    internet -> cloudflare [label=\"HTTPS\"];").unwrap();
    writeln!(src, "    cloudflare -> caddy_pub [label=\"proxy\"];").unwrap();
    writeln!(src, "  }}").unwrap();

    // ── PRIVATE PATH (bottom) ──
    writeln!(src, "  subgraph cluster_private {{").unwrap();
    writeln!(src, "    label=\"PRIVATE PATH (WireGuard)\"; style=dashed; color=\"{}\"; fontcolor=\"{}\"; fontsize=11;", "#57A6D6", "#57A6D6").unwrap();
    writeln!(src, "    wg [label=\"WireGuard\\n10.0.0.0/24\",shape=cylinder,fillcolor=\"{}\",color=\"{}\"];", D_CARD, "#57A6D6").unwrap();
    writeln!(src, "    hickory [label=\"Hickory DNS\\n*.app zones\",shape=diamond,fillcolor=\"{}\",color=\"{}\"];", D_CARD, "#57A6D6").unwrap();
    writeln!(src, "    caddy_int [label=\"Caddy internal\\nforward_auth\",shape=hexagon,fillcolor=\"{}\",color=\"{}\"];", D_CARD, "#57A6D6").unwrap();
    writeln!(src, "    wg -> hickory [label=\"resolve\",color=\"{}\"];", "#57A6D6").unwrap();
    writeln!(src, "    hickory -> caddy_int [label=\"route\",color=\"{}\"];", "#57A6D6").unwrap();
    writeln!(src, "  }}").unwrap();

    // ── VM TARGETS (right side) ──
    writeln!(src, "  subgraph cluster_vms {{").unwrap();
    writeln!(src, "    label=\"CONTAINERS ({}/{})\"; style=filled; fillcolor=\"{}\"; fontcolor=\"{}\"; color=\"{}\"; fontsize=11;",
        total_ctrs, total_declared, D_HEAD, D_TEXT, D_OK).unwrap();

    for vm in &data.vms {
        let id = gv_id(&vm.name);
        let color = match vm.status {
            crate::types::VmStatus::Healthy => D_OK,
            crate::types::VmStatus::Warning => D_WARN,
            crate::types::VmStatus::Critical => D_CRIT,
            _ => D_DIM,
        };
        if vm.containers_total > 0 {
            writeln!(src, "    {} [label=\"{}\\n{}/{} ctrs\",color=\"{}\"];",
                id, vm.name, vm.containers_running, vm.containers_total, color).unwrap();
        } else if vm.status != crate::types::VmStatus::Critical {
            writeln!(src, "    {} [label=\"{}\\n{}/{} ctrs\",color=\"{}\",style=\"filled,dashed\"];",
                id, vm.name, vm.containers_running, vm.containers_total, D_DIM).unwrap();
        }
    }
    writeln!(src, "  }}").unwrap();

    // ── EDGES: public path → VMs ──
    for vm in &data.vms {
        if vm.containers_total == 0 { continue; }
        let id = gv_id(&vm.name);
        writeln!(src, "  caddy_pub -> {} [label=\"{}\"];", id, vm.ip).unwrap();
    }

    // ── EDGES: private path → VMs ──
    for vm in &data.vms {
        if vm.containers_total == 0 { continue; }
        let id = gv_id(&vm.name);
        writeln!(src, "  caddy_int -> {} [style=dashed,color=\"{}\"];", id, "#57A6D6").unwrap();
    }

    writeln!(src, "}}").unwrap();
    dot_svg(&src)
}

// ── 6. CI/CD Pipeline (D2) ────────────────────────────────────────

pub fn cicd_pipeline_d2(data: &ReportData) -> String {
    let gha_ok = data.gha_runs.iter().filter(|r| r.conclusion == "success").count();
    let gha_total = data.gha_runs.len();
    let dag_count = data.dags.len();

    let mut src = String::new();
    writeln!(src, "direction: right").unwrap();
    writeln!(src, "dev: \"Developer\" {{ shape: person; style.fill: \"{}\"; style.font-color: \"{}\" }}", D_CARD, D_TEXT).unwrap();
    writeln!(src, "github: \"GitHub\\n{} repos\" {{ shape: rectangle; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        data.repos.len(), D_CARD, D_TEXT).unwrap();
    writeln!(src, "gha: \"GHA\\n{}/{} OK\" {{ shape: hexagon; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        gha_ok, gha_total, D_CARD, D_TEXT).unwrap();
    writeln!(src, "ghcr: \"GHCR\\n{} images\" {{ shape: cylinder; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        data.ghcr_total, D_CARD, D_TEXT).unwrap();
    writeln!(src, "vms: \"VMs\\n{}\" {{ shape: rectangle; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        data.vms.len(), D_CARD, D_TEXT).unwrap();
    writeln!(src, "dagu: \"Dagu\\n{} DAGs\" {{ shape: hexagon; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        dag_count, D_HEAD, D_TEXT).unwrap();
    writeln!(src, "dev -> github -> gha -> ghcr -> vms").unwrap();
    writeln!(src, "github -> dagu -> vms").unwrap();

    d2_svg(&src)
}

// ── 7. Provider Map (Graphviz) ────────────────────────────────────

pub fn provider_map_dot(data: &ReportData) -> String {
    if data.vm_finops.is_empty() {
        return String::new();
    }

    let mut src = String::new();
    writeln!(src, "digraph Providers {{").unwrap();
    writeln!(src, "  bgcolor=\"{}\";", D_BG).unwrap();
    writeln!(src, "  node [style=filled,fillcolor=\"{}\",fontcolor=\"{}\",color=\"{}\",fontname=\"Courier\",fontsize=10];",
        D_CARD, D_TEXT, D_OK).unwrap();
    writeln!(src, "  edge [color=\"{}\",style=invis];", D_OK).unwrap();

    // Group by provider
    let mut groups: std::collections::BTreeMap<String, Vec<&VmFinops>> =
        std::collections::BTreeMap::new();
    for vm in &data.vm_finops {
        groups.entry(vm.provider.clone()).or_default().push(vm);
    }

    for (provider, vms) in &groups {
        let pid = gv_id(provider);
        writeln!(src, "  subgraph cluster_{} {{", pid).unwrap();
        writeln!(src, "    label=\"{}\";", provider).unwrap();
        writeln!(src, "    style=filled; fillcolor=\"{}\"; fontcolor=\"{}\"; color=\"{}\";", D_HEAD, D_TEXT, D_OK).unwrap();
        for vm in vms {
            let id = gv_id(&vm.alias);
            let tier_label = if vm.tier == "Free" { "FREE" } else { "PAID" };
            writeln!(src, "    {} [label=\"{}\\n{}cpu/{}GB\\n{}\"];",
                id, vm.alias, vm.cpu, vm.ram_gb, tier_label).unwrap();
        }
        writeln!(src, "  }}").unwrap();
    }

    writeln!(src, "}}").unwrap();
    dot_svg(&src)
}

// ── 8. Auth Flow (PlantUML sequence) ──────────────────────────────

pub fn auth_flow_plantuml(data: &ReportData) -> String {
    let _ = data; // static auth flow diagram

    let mut src = String::new();
    writeln!(src, "@startuml").unwrap();
    writeln!(src, "skinparam backgroundColor {}", D_BG).unwrap();
    writeln!(src, "skinparam defaultFontColor {}", D_TEXT).unwrap();
    writeln!(src, "skinparam defaultFontName Courier").unwrap();
    writeln!(src, "skinparam sequence {{").unwrap();
    writeln!(src, "  ArrowColor {}", D_OK).unwrap();
    writeln!(src, "  LifeLineBorderColor {}", D_OK).unwrap();
    writeln!(src, "  LifeLineBackgroundColor {}", D_CARD).unwrap();
    writeln!(src, "  ParticipantBorderColor {}", D_OK).unwrap();
    writeln!(src, "  ParticipantBackgroundColor {}", D_CARD).unwrap();
    writeln!(src, "  ParticipantFontColor {}", D_TEXT).unwrap();
    writeln!(src, "}}").unwrap();
    writeln!(src, "participant \"Browser\" as B").unwrap();
    writeln!(src, "participant \"Caddy\" as C").unwrap();
    writeln!(src, "participant \"Authelia\" as A").unwrap();
    writeln!(src, "participant \"Service\" as S").unwrap();
    writeln!(src, "B -> C: GET /app").unwrap();
    writeln!(src, "C -> A: forward_auth").unwrap();
    writeln!(src, "A --> B: 302 login page").unwrap();
    writeln!(src, "B -> A: POST credentials + TOTP").unwrap();
    writeln!(src, "A --> B: Set session cookie").unwrap();
    writeln!(src, "B -> C: GET /app (with cookie)").unwrap();
    writeln!(src, "C -> A: verify session").unwrap();
    writeln!(src, "A --> C: 200 OK").unwrap();
    writeln!(src, "C -> S: proxy request").unwrap();
    writeln!(src, "S --> B: response").unwrap();
    writeln!(src, "@enduml").unwrap();

    plantuml_svg(&src)
}

// ── 9. Storage Map (D2) ──────────────────────────────────────────

pub fn storage_map_d2(data: &ReportData) -> String {
    let total_vols: usize = data.vms.iter().map(|v| v.runtime_volumes.len()).sum();
    let db_count = data.databases.iter().filter(|d| d.enabled).count();
    let bucket_count = data.cloud_buckets.len();

    let ghcr_disk = if data.github_disk_kb > 1_048_576 {
        format!("{:.1}GB", data.github_disk_kb as f64 / 1_048_576.0)
    } else if data.github_disk_kb > 1024 {
        format!("{:.0}MB", data.github_disk_kb as f64 / 1024.0)
    } else if data.github_disk_kb > 0 {
        format!("{}KB", data.github_disk_kb)
    } else {
        "?".into()
    };

    let mut src = String::new();
    writeln!(src, "direction: right").unwrap();
    writeln!(src, "oci: \"OCI S3\\n{} buckets\" {{ shape: cylinder; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        bucket_count, D_HEAD, D_TEXT).unwrap();
    writeln!(src, "ghcr: \"GHCR\\n{} imgs\\n{}\" {{ shape: cylinder; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        data.ghcr_total, ghcr_disk, D_CARD, D_TEXT).unwrap();
    writeln!(src, "volumes: \"Docker Volumes\\n{}\" {{ shape: rectangle; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        total_vols, D_CARD, D_TEXT).unwrap();
    writeln!(src, "dbs: \"Databases\\n{}\" {{ shape: cylinder; style.fill: \"{}\"; style.font-color: \"{}\" }}",
        db_count, D_CARD, D_TEXT).unwrap();
    writeln!(src, "oci <- volumes: backup").unwrap();
    writeln!(src, "ghcr -> volumes: pull").unwrap();
    writeln!(src, "volumes -> dbs").unwrap();

    d2_svg(&src)
}

// ── 10. Service Mesh (Graphviz) ───────────────────────────────────

pub fn service_mesh_dot(data: &ReportData) -> String {
    let mut src = String::new();
    writeln!(src, "digraph ServiceMesh {{").unwrap();
    writeln!(src, "  bgcolor=\"{}\";", D_BG).unwrap();
    writeln!(src, "  node [style=filled,fillcolor=\"{}\",fontcolor=\"{}\",color=\"{}\",fontname=\"Courier\",fontsize=9];",
        D_CARD, D_TEXT, D_OK).unwrap();
    writeln!(src, "  edge [color=\"{}\"];", D_OK).unwrap();
    writeln!(src, "  rankdir=LR;").unwrap();

    // Caddy as central router
    writeln!(src, "  caddy [label=\"Caddy\\nReverse Proxy\",shape=doubleoctagon,fillcolor=\"{}\"];", D_HEAD).unwrap();

    // Group services by VM, connect through Caddy
    for vm in &data.vms {
        if vm.containers_total == 0 { continue; }
        let vm_id = gv_id(&vm.name);
        writeln!(src, "  {} [label=\"{}\\n{} svcs\",shape=box3d];", vm_id, vm.name, vm.containers_running).unwrap();
        writeln!(src, "  caddy -> {};", vm_id).unwrap();
    }

    // Show services with domains as leaf nodes (up to 10 to keep readable)
    let svcs_with_domain: Vec<&ServiceEntry> = data.services.iter()
        .filter(|s| s.enabled && !s.domain.is_empty())
        .take(10)
        .collect();
    for svc in &svcs_with_domain {
        let svc_id = gv_id(&svc.name);
        let short_domain = svc.domain.split('.').next().unwrap_or(&svc.domain);
        writeln!(src, "  {} [label=\"{}\",shape=component];", svc_id, short_domain).unwrap();
        // Connect to its VM
        let vm_id = gv_id(&svc.vm);
        writeln!(src, "  {} -> {};", vm_id, svc_id).unwrap();
    }

    writeln!(src, "}}").unwrap();
    dot_svg(&src)
}

// ── 11. VM Resources (D2) ────────────────────────────────────────

pub fn vm_resource_d2(data: &ReportData) -> String {
    if data.vm_finops.is_empty() {
        return String::new();
    }

    let mut src = String::new();
    writeln!(src, "direction: right").unwrap();

    let mut sorted: Vec<&VmFinops> = data.vm_finops.iter().collect();
    sorted.sort_by(|a, b| {
        let sa = a.cpu as f64 * a.ram_gb;
        let sb = b.cpu as f64 * b.ram_gb;
        sb.partial_cmp(&sa).unwrap_or(std::cmp::Ordering::Equal)
    });

    for vm in &sorted {
        let id = gv_id(&vm.alias);
        let tier_label = if vm.tier == "Free" { "FREE" } else { "PAID" };
        let fill = if vm.tier == "Free" { D_CARD } else { D_HEAD };
        writeln!(src, "{}: \"{}\\n{}cpu / {}GB RAM\\n{} svcs | {}\" {{ shape: rectangle; style.fill: \"{}\"; style.font-color: \"{}\" }}",
            id, vm.alias, vm.cpu, vm.ram_gb, vm.services, tier_label, fill, D_TEXT).unwrap();
    }

    // Connect in a chain to show relative sizing
    let ids: Vec<String> = sorted.iter().map(|v| gv_id(&v.alias)).collect();
    for w in ids.windows(2) {
        writeln!(src, "{} -> {}", w[0], w[1]).unwrap();
    }

    d2_svg(&src)
}

// ── 12. Backup Flow (PlantUML) ───────────────────────────────────

pub fn backup_flow_plantuml(data: &ReportData) -> String {
    let backup_count: usize = data.vms.iter().map(|v| v.backups.len()).sum();
    let bucket_count = data.cloud_buckets.len();

    let mut src = String::new();
    writeln!(src, "@startuml").unwrap();
    writeln!(src, "skinparam backgroundColor {}", D_BG).unwrap();
    writeln!(src, "skinparam defaultFontColor {}", D_TEXT).unwrap();
    writeln!(src, "skinparam defaultFontName Courier").unwrap();
    writeln!(src, "skinparam component {{").unwrap();
    writeln!(src, "  BackgroundColor {}", D_CARD).unwrap();
    writeln!(src, "  BorderColor {}", D_OK).unwrap();
    writeln!(src, "  FontColor {}", D_TEXT).unwrap();
    writeln!(src, "}}").unwrap();
    writeln!(src, "skinparam database {{").unwrap();
    writeln!(src, "  BackgroundColor {}", D_CARD).unwrap();
    writeln!(src, "  BorderColor {}", D_OK).unwrap();
    writeln!(src, "  FontColor {}", D_TEXT).unwrap();
    writeln!(src, "}}").unwrap();
    writeln!(src, "skinparam ArrowColor {}", D_OK).unwrap();
    writeln!(src, "component \"Dagu\\nScheduler\" as dagu").unwrap();
    writeln!(src, "component \"restic\\nBackup Tool\" as restic").unwrap();
    writeln!(src, "database \"Docker Volumes\\n{} backups\" as volumes", backup_count).unwrap();
    writeln!(src, "database \"OCI S3\\n{} buckets\" as s3", bucket_count).unwrap();
    writeln!(src, "dagu --> restic : triggers").unwrap();
    writeln!(src, "restic --> volumes : snapshot").unwrap();
    writeln!(src, "restic --> s3 : upload").unwrap();
    writeln!(src, "@enduml").unwrap();

    plantuml_svg(&src)
}

// ── Public: generate all diagrams ────────────────────────────────

/// All diagram results keyed by (title, tool_name, svg_content)
pub fn generate_all(data: &ReportData) -> Vec<(&'static str, &'static str, String)> {
    vec![
        ("WireGuard Mesh", "graphviz", wireguard_mesh_dot(data)),
        ("Security Layers", "d2", security_layers_d2(data)),
        ("Data Flow", "plantuml", data_flow_plantuml(data)),
        ("DNS Chain", "pikchr", dns_chain_pikchr(data)),
        ("Container Distribution", "graphviz", container_distribution_dot(data)),
        ("CI/CD Pipeline", "d2", cicd_pipeline_d2(data)),
        ("Provider Map", "graphviz", provider_map_dot(data)),
        ("Auth Flow", "plantuml", auth_flow_plantuml(data)),
        ("Storage Map", "d2", storage_map_d2(data)),
        ("Service Mesh", "graphviz", service_mesh_dot(data)),
        ("VM Resources", "d2", vm_resource_d2(data)),
        ("Backup Flow", "plantuml", backup_flow_plantuml(data)),
    ]
}
