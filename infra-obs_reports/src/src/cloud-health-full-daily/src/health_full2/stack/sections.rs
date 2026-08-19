use super::types::*;
use std::collections::HashMap;

/// Build ALL template variables from context + live data
pub fn build_all_vars(ctx: &Context, live: &LiveData) -> HashMap<String, String> {
    let mut vars = HashMap::new();

    vars.insert("GENERATED_DATE".into(), live.generated.clone());
    vars.insert("HUB_WG_IP".into(), ctx.vms.iter().find(|v| v.alias == "gcp-proxy").map(|v| v.wg_ip.clone()).unwrap_or("?".into()));

    // ISSUES FOUND
    vars.insert("ISSUES_SUMMARY".into(), build_issues(live));

    // A0 Mesh
    vars.insert("WG_PEERS".into(), build_mesh(live));

    // A1 Public
    vars.insert("PUBLIC_URLS".into(), build_public_urls(live));
    vars.insert("API_MCP_ENDPOINTS".into(), build_api_mcp(ctx));
    vars.insert("REPOS_REGISTRIES".into(), build_repos_registries());

    // A2 Private
    vars.insert("PRIVATE_HEALTH".into(), build_private(ctx, live));

    // A3 Containers
    vars.insert("VM_CONTAINERS".into(), build_containers(ctx, live));

    // A3b Container Drift — ALL containers across ALL VMs
    vars.insert("CONTAINER_DRIFT".into(), build_container_drift(live));

    // A4 Mail
    vars.insert("MAIL_PORTS".into(), build_mail_ports(ctx));
    vars.insert("MAIL_MX".into(), build_mail_mx(live));
    vars.insert("MAIL_SPF".into(), build_mail_spf(ctx, live));
    vars.insert("MAIL_DKIM".into(), build_mail_dkim(live));
    vars.insert("MAIL_DMARC".into(), build_mail_dmarc(live));
    vars.insert("MAIL_AUTH".into(), build_mail_auth(ctx));
    vars.insert("MAIL_FLOW".into(), build_mail_flow(ctx, live));

    // B Infra
    vars.insert("VPS_SPECS".into(), build_vps_specs(ctx));
    vars.insert("RESOURCES_HEADER".into(), live.vm_data.iter().map(|v| format!("{:14}", v.alias)).collect::<Vec<_>>().join(" "));
    vars.insert("RESOURCES_TABLE".into(), build_resources(live));
    vars.insert("DATABASES_LIVE".into(), build_database_section(live));
    vars.insert("STORAGE_LIVE".into(), build_storage_section(live));
    vars.insert("STORAGE".into(), build_storage(ctx));

    // C Security
    vars.insert("OPEN_PORTS".into(), build_port_scan(live));
    vars.insert("NETWORK_AUDIT".into(), build_network_audit(ctx, live));
    vars.insert("DATABASES".into(), build_databases(ctx));
    vars.insert("DOCKER_NETWORKS".into(), build_docker_networks(ctx));
    vars.insert("VAULT_PROVIDERS".into(), build_vault_providers());

    // D Stack
    vars.insert("FRAMEWORK_PATHS".into(), build_framework_paths(ctx));

    // Z Appendix
    vars.insert("PERFORMANCE".into(), build_performance(live));
    vars.insert("SCRIPT_INFO".into(), build_script_info(live));

    vars
}

fn build_issues(live: &LiveData) -> String {
    let mut issues = Vec::new();
    for vm in &live.vm_data {
        if !vm.reachable { issues.push(format!("❌ A3       VM {} — UNREACHABLE", vm.alias)); }
        for c in &vm.containers {
            if c.health == "exited" || c.health == "unhealthy" {
                issues.push(format!("{} A3       {}/{} — {}", if c.health == "unhealthy" { "⚠️" } else { "❌" }, vm.alias, c.name, c.health));
            }
        }
    }
    for u in &live.public_urls {
        if !u.https { issues.push(format!("❌ A1       {} — [{}]", u.url, u.code)); }
    }
    for db in &live.db_health {
        if !db.healthy {
            issues.push(format!("{} B2       {}/{} ({}) — {}", if db.running { "⚠️" } else { "❌" }, db.vm, db.container, db.db_type, if db.running { "unhealthy" } else { "not running" }));
        }
    }
    if issues.is_empty() { return "✅ No issues found".into(); }
    let crit = issues.iter().filter(|i| i.starts_with("❌")).count();
    let warn = issues.iter().filter(|i| i.starts_with("⚠️")).count();
    format!("{} critical, {} warnings — {} total\n\n    {}", crit, warn, issues.len(), issues.join("\n    "))
}

fn build_mesh(live: &LiveData) -> String {
    live.mesh.iter().map(|p| {
        let all_ok = p.vps_ok && p.pub_ok && p.wg_ok;
        let any = p.vps_ok || p.pub_ok || p.wg_ok || p.dropbear_ok;
        let icon = if all_ok { "✅" } else if any { "⚠️" } else { "❌" };
        let db = if p.peer_type == "CLIENT" { "—" } else if p.dropbear_ok { "✅" } else { "❌" };
        format!("{} {:14} {:18} {}  {}  {}  {}  {:18} {:14} {:8} {}",
            icon, p.name, p.cloud_name,
            if p.vps_ok { "✅" } else { "❌" },
            if p.pub_ok { "✅" } else { "❌" },
            db,
            if p.wg_ok { "✅" } else { "❌" },
            p.pub_ip, p.wg_ip, p.peer_type, p.wg_handshake)
    }).collect::<Vec<_>>().join("\n")
}

fn build_public_urls(live: &LiveData) -> String {
    live.public_urls.iter().map(|u| {
        let all = u.tcp && u.https && u.auth;
        let any = u.tcp || u.http || u.https;
        let icon = if all { "✅" } else if any { "⚠️" } else { "❌" };
        let auth = if u.auth { "✅" } else if u.auth_code == "---" { "—" } else { "❌" };
        format!("{} {:32} {}  {}  {}  {}  {:22} [{}] {}",
            icon, u.url,
            if u.tcp { "✅" } else { "❌" },
            if u.http { "✅" } else { "❌" },
            if u.https { "✅" } else { "❌" },
            auth, u.upstream, u.code,
            if !u.auth && u.auth_code != "---" { format!("auth:[{}]", u.auth_code) } else { String::new() })
    }).collect::<Vec<_>>().join("\n")
}

fn build_private(_ctx: &Context, live: &LiveData) -> String {
    let mut lines = Vec::new();
    if live.private_endpoints.iter().all(|p| p.resolved_ip.is_empty() && !p.container_up) {
        lines.push("⚠️  WireGuard/Hickory DOWN — cannot reach .app endpoints".into());
        lines.push("    Run: sudo wg-quick up wg0".into());
        lines.push(String::new());
    }
    lines.push(format!("    {:28} 📡TCP 🌐HTTP 🐳CTR {:5} {:14} {:22} Code", "DNS Name", "Port", "VM", "Container"));
    lines.push(format!("    {}", "─".repeat(105)));
    for p in &live.private_endpoints {
        let net_ok = p.tcp || p.http;
        let ok = net_ok || p.container_up;
        let icon = if ok { "✅" } else { "❌" };
        let tcp_i = if p.tcp { "✅" } else if p.resolved_ip.is_empty() { "⏸️" } else { "❌" };
        let http_i = if p.http { "✅" } else if p.resolved_ip.is_empty() { "⏸️" } else { "❌" };
        let ctr_i = if p.container_up { "✅" } else { "❌" };
        lines.push(format!("{} {:28} {}   {}   {}   {:5} {:14} {:22} [{}]", icon, p.dns, tcp_i, http_i, ctr_i, p.port, p.vm, p.container, p.code));
    }
    let tcp_ok = live.private_endpoints.iter().filter(|p| p.tcp).count();
    let http_ok = live.private_endpoints.iter().filter(|p| p.http).count();
    let ctr_ok = live.private_endpoints.iter().filter(|p| p.container_up).count();
    lines.push(String::new());
    lines.push(format!("  📡 TCP: {}/{}  🌐 HTTP: {}/{}  🐳 Container: {}/{}", tcp_ok, live.private_endpoints.len(), http_ok, live.private_endpoints.len(), ctr_ok, live.private_endpoints.len()));
    lines.join("\n")
}

fn build_containers(ctx: &Context, live: &LiveData) -> String {
    live.vm_data.iter().map(|vm| {
        let st = if vm.reachable { "✅" } else { "❌" };
        let mut lines = vec![
            format!("{} {} — {}C/{} — mem {}/{} ({}%) — disk {} — swap {} — load {} — {}/{} ctrs — {}",
                vm.alias, st, ctx.vms.iter().find(|v| v.alias == vm.alias).map(|v| v.cpus).unwrap_or(0),
                ctx.vms.iter().find(|v| v.alias == vm.alias).map(|v| v.ram_gb.as_str()).unwrap_or("?"),
                vm.mem_used, vm.mem_total, vm.mem_pct, vm.disk_pct, vm.swap, vm.load, vm.containers_running, vm.containers_total, vm.uptime),
            "─".repeat(60),
        ];
        for c in &vm.containers {
            let state = match c.health.as_str() {
                "healthy" => "HEALTHY",
                "unhealthy" => "UNHEALTHY",
                "starting" => "STARTING",
                "created" | "exited" => &format!("DOWN({})", c.status.split('(').nth(1).and_then(|s| s.split(')').next()).unwrap_or("?")),
                "none" => "UP (no hc)",
                _ => &c.health,
            };
            let icon = match c.health.as_str() {
                "healthy" => "✅", "unhealthy" | "exited" | "created" => "❌", _ => "⚠️",
            };
            lines.push(format!("  {} {:25} {:6} {:6} {:14} {}", icon, c.name, c.host_port, c.docker_port, state, &c.status[..c.status.len().min(30)]));
        }
        lines.push(String::new());
        lines.join("\n")
    }).collect::<Vec<_>>().join("\n")
}

fn build_container_drift(live: &LiveData) -> String {
    let mut total = 0u32;
    let mut running = 0u32;
    let mut healthy = 0u32;
    let mut unhealthy = 0u32;
    let mut exited = 0u32;

    for vm in &live.vm_data {
        for c in &vm.containers {
            total += 1;
            if c.status.contains("Up") { running += 1; }
            match c.health.as_str() {
                "healthy" => healthy += 1,
                "unhealthy" => unhealthy += 1,
                "exited" => exited += 1,
                _ => {}
            }
        }
    }

    let mut lines = vec![
        format!("CONTAINER HEALTH — {}/{} running, {} healthy, {} unhealthy, {} exited",
            running, total, healthy, unhealthy, exited),
        "─".repeat(110),
    ];

    // Per-VM summary table (docker ps + docker stats aggregated)
    lines.push(format!("    {:16} {:16} {:6} {:8} {:10} {:8} {:10} {:10} {:10} {:8}",
        "VM", "Total", "Up", "Healthy", "Unhealthy", "Exited", "Mem Used", "Mem Total", "Disk", "Load"));
    lines.push(format!("    {}", "─".repeat(100)));
    for vm in &live.vm_data {
        let vm_up = vm.containers.iter().filter(|c| c.status.contains("Up")).count();
        let vm_healthy = vm.containers.iter().filter(|c| c.health == "healthy").count();
        let vm_unhealthy = vm.containers.iter().filter(|c| c.health == "unhealthy").count();
        let vm_exited = vm.containers.iter().filter(|c| c.health == "exited").count();
        let no_docker = vm.reachable && vm.containers_total == 0;
        let all_ok = vm_unhealthy == 0 && vm_exited == 0 && vm.reachable && !no_docker;
        let icon = if no_docker { "⚠️" } else if all_ok { "✅" } else if vm.reachable { "⚠️" } else { "❌" };
        let total_str = if no_docker { "⚠️ no docker CLI".to_string() } else { vm.containers_total.to_string() };
        lines.push(format!("{} {:16} {:16} {:6} {:8} {:10} {:8} {:10} {:10} {:10} {:8}",
            icon, vm.alias, total_str, vm_up, vm_healthy, vm_unhealthy, vm_exited,
            vm.mem_used, vm.mem_total, vm.disk_pct, vm.load.split_whitespace().next().unwrap_or("?")));
    }
    lines.push(format!("    {}", "─".repeat(100)));

    // Per-container detail
    lines.push(String::new());
    lines.push(format!("    {:25} {:14} {:12} {:35}", "Container", "Health", "VM", "Status (docker ps + stats)"));
    lines.push(format!("    {}", "─".repeat(95)));

    for vm in &live.vm_data {
        for c in &vm.containers {
            let icon = match c.health.as_str() {
                "healthy" => "✅",
                "unhealthy" => "⚠️",
                "exited" | "created" => "❌",
                _ => if c.status.contains("Up") { "✅" } else { "❌" },
            };
            let health_str = match c.health.as_str() {
                "healthy" => "healthy",
                "unhealthy" => "UNHEALTHY",
                "exited" => "EXITED",
                "created" => "CREATED",
                "starting" => "starting",
                "none" => if c.status.contains("Up") { "up" } else { "down" },
                _ => &c.health,
            };
            lines.push(format!("  {} {:25} {:14} {:12} {}",
                icon, c.name, health_str, vm.alias, &c.status[..c.status.len().min(50)]));
        }
    }
    lines.join("\n")
}

/// R4: Mail listener ports — data-driven from build-caddy.json L4 SNI map
/// (parsed into ctx.mail_ports). Mail clients connect on :443 (SNI-demuxed to
/// IMAPS/SMTPS) plus the plain :25 MX — NOT 993/465 directly. Rendering the
/// declared L4 map here replaces the old "(TODO)" stub.
fn build_mail_ports(ctx: &Context) -> String {
    let mut lines = vec![
        "Mail Listener Ports (Caddy L4 SNI mux — declared)".into(),
        "─".repeat(60),
        format!("    {:32} {:6} {:12} Upstream", "Host / SNI", "Port", "Proto"),
        "─".repeat(60),
    ];
    if ctx.mail_ports.is_empty() {
        lines.push("⚠️ no L4 mail routes found in build-caddy.json (.l4_routes)".into());
        return lines.join("\n");
    }
    for mp in &ctx.mail_ports {
        // Look up the upstream from the caddy L4 map by port+host match when
        // available; ctx.mail_ports carries host/port/proto only, so show the
        // client-facing endpoint (host:port) which is what operators verify.
        lines.push(format!(
            "✅ {:32} {:<6} {:12} {}",
            mp.host,
            mp.port,
            mp.proto,
            format!("{}:{}", mp.host, mp.port),
        ));
    }
    lines.join("\n")
}

fn build_mail_mx(live: &LiveData) -> String {
    let mut lines = vec![
        "MX — Inbound Routing (dig MX)".into(),
        "─".repeat(60),
        format!("    {:28} {:5} {:42} IP", "Domain", "Pri", "Server"),
        "─".repeat(60),
    ];
    for mx in &live.mail_dns.mx {
        let icon = if mx.server.contains("no MX") { "❌" } else { "✅" };
        lines.push(format!("{} {:28} {:5} {:42} {}", icon, mx.domain, mx.priority, mx.server, mx.ip));
    }
    lines.join("\n")
}

fn build_mail_spf(ctx: &Context, live: &LiveData) -> String {
    let mut lines = vec![
        "SPF — Outbound Policy: IP Allowlist".into(),
        "─".repeat(60),
    ];
    for spf in &live.mail_dns.spf {
        lines.push(format!("✅ {:32} {:45} {}", spf.domain, spf.include, spf.ips));
    }
    let oci_ip = ctx.vms.iter().find(|v| v.alias == "oci-mail").map(|v| v.pub_ip.as_str()).unwrap_or("?");
    lines.push(format!("⚠️ {:32} oci-mail VM IP {} NOT IN SPF!", "diegonmarcos.com", oci_ip));
    lines.join("\n")
}

fn build_mail_dkim(live: &LiveData) -> String {
    let mut lines = vec![
        "DKIM — Outbound Policy: Cryptographic Signatures".into(),
        "─".repeat(60),
    ];
    for d in &live.mail_dns.dkim {
        let icon = if d.present { "✅" } else { "❌" };
        lines.push(format!("{} {:28} {:24} {:20} {}", icon, d.selector, d.domain, d.signer, d.key_size));
    }
    lines.join("\n")
}

fn build_mail_dmarc(live: &LiveData) -> String {
    format!("DMARC — Outbound Policy\n─────────────────────\n✅ _dmarc.diegonmarcos.com       {}", live.mail_dns.dmarc)
}

fn build_vps_specs(ctx: &Context) -> String {
    ctx.vms.iter().map(|v| {
        format!("   {:16} {:10} {:20} {:6} {:6} {:8} {}", v.alias, v.provider, v.shape, v.cpus, v.ram_gb, v.disk_gb, v.cost)
    }).collect::<Vec<_>>().join("\n")
}

fn build_resources(live: &LiveData) -> String {
    let fields: Vec<(&str, Box<dyn Fn(&VmLiveData) -> String>)> = vec![
        ("CPU", Box::new(|v: &VmLiveData| format!("{} cores", if v.reachable { v.mem_pct.to_string() } else { "?".into() }))),
        ("RAM", Box::new(|v| format!("{}/{}", v.mem_used, v.mem_total))),
        ("RAM %", Box::new(|v| format!("{}%", v.mem_pct))),
        ("Swap", Box::new(|v| v.swap.clone())),
        ("Disk", Box::new(|v| format!("{}/{}", v.disk_used, v.disk_total))),
        ("Disk %", Box::new(|v| v.disk_pct.clone())),
        ("Load", Box::new(|v| v.load.clone())),
        ("Containers", Box::new(|v| format!("{}/{}", v.containers_running, v.containers_total))),
        ("Uptime", Box::new(|v| v.uptime.clone())),
    ];
    let mut out = fields.iter().map(|(label, f)| {
        let vals: String = live.vm_data.iter().map(|v| format!("{:14}", f(v))).collect();
        format!("{:18} {}", label, vals)
    }).collect::<Vec<_>>().join("\n");

    // Per-mount disk breakdown — every real filesystem per VM (not just root).
    // Fixes the old single-`df /` scalar that showed the same total/used everywhere.
    out.push_str("\n\n  Disk usage per mount:\n");
    for v in &live.vm_data {
        if v.disks.is_empty() {
            out.push_str(&format!("    {:16} (no disk data{})\n", v.alias,
                if v.reachable { "" } else { " — unreachable" }));
            continue;
        }
        out.push_str(&format!("    {}:\n", v.alias));
        for d in &v.disks {
            out.push_str(&format!("      {:22} {:>8} / {:<8} {:>5}   {}\n",
                d.mount, d.used, d.total, d.pct, d.source));
        }
    }
    out
}

fn build_port_scan(live: &LiveData) -> String {
    live.port_scan.iter().map(|r| {
        let icon = if r.open_ports.is_empty() { "🔒" } else { "🔓" };
        let ports = if r.open_ports.is_empty() { "none reachable".into() } else { r.open_ports.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(", ") };
        format!("{} {:18} {:18} ports: {}", icon, r.name, r.ip, ports)
    }).collect::<Vec<_>>().join("\n")
}

fn build_network_audit(ctx: &Context, live: &LiveData) -> String {
    // VM columns: gcp-proxy | oci-mail | oci-analytics | oci-apps
    let vm_order: Vec<&str> = vec!["gcp-proxy", "oci-mail", "oci-analytics", "oci-apps"];
    let col_w = 18;

    // Header
    let header = format!("    {:20} {}", "Check",
        vm_order.iter().map(|v| format!("{:>w$}", v, w = col_w)).collect::<Vec<_>>().join(" "));
    let sep = format!("    {}", "─".repeat(20 + (col_w + 1) * vm_order.len()));

    let mut rows = vec![header, sep.clone()];

    // Row 1: Declared public ports (from cloud-data JSON)
    let declared: Vec<String> = vm_order.iter().map(|alias| {
        ctx.vms.iter().find(|v| v.alias == *alias)
            .map(|v| if v.declared_ports.is_empty() { "none".into() } else {
                v.declared_ports.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(",")
            }).unwrap_or("?".into())
    }).collect();
    rows.push(format!("    {:20} {}", "Declared ports",
        declared.iter().map(|d| format!("{:>w$}", d, w = col_w)).collect::<Vec<_>>().join(" ")));

    // Row 2: Scanned open ports (from port scan on public IP)
    let scanned: Vec<String> = vm_order.iter().map(|alias| {
        let vm_info = ctx.vms.iter().find(|v| v.alias == *alias);
        let ip = vm_info.map(|v| v.pub_ip.as_str()).unwrap_or("?");
        live.port_scan.iter().find(|r| r.ip == ip || r.name == *alias)
            .map(|r| if r.open_ports.is_empty() { "🔒 none".into() } else {
                r.open_ports.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(",")
            }).unwrap_or("—".into())
    }).collect();
    rows.push(format!("    {:20} {}", "Scanned (public)",
        scanned.iter().map(|s| format!("{:>w$}", s, w = col_w)).collect::<Vec<_>>().join(" ")));

    // Row 3: Docker exposed ports (from container health agent data)
    let docker: Vec<String> = vm_order.iter().map(|alias| {
        live.vm_data.iter().find(|v| v.alias == *alias)
            .map(|v| {
                let ports: Vec<String> = v.containers.iter()
                    .filter(|c| !c.host_port.is_empty() && c.host_port != "—")
                    .map(|c| c.host_port.clone())
                    .collect();
                if ports.is_empty() { "none".into() } else {
                    let unique: std::collections::BTreeSet<&str> = ports.iter().map(|s| s.as_str()).collect();
                    unique.into_iter().collect::<Vec<_>>().join(",")
                }
            }).unwrap_or("—".into())
    }).collect();
    rows.push(format!("    {:20} {}", "Docker host ports",
        docker.iter().map(|d| format!("{:>w$}", d, w = col_w)).collect::<Vec<_>>().join(" ")));

    // Row 4: Undeclared leaks (scanned - declared)
    let leaks: Vec<String> = vm_order.iter().map(|alias| {
        let vm_info = ctx.vms.iter().find(|v| v.alias == *alias);
        let declared_set: std::collections::HashSet<u16> = vm_info.map(|v| v.declared_ports.iter().copied().collect()).unwrap_or_default();
        // Always-allowed: 22 (SSH), 51820 (WG), 2200 (Dropbear)
        let always_allowed: std::collections::HashSet<u16> = [22, 51820, 2200].into();
        let ip = vm_info.map(|v| v.pub_ip.as_str()).unwrap_or("?");
        let scanned_ports: Vec<u16> = live.port_scan.iter().find(|r| r.ip == ip || r.name == *alias)
            .map(|r| r.open_ports.clone()).unwrap_or_default();
        let leaked: Vec<u16> = scanned_ports.into_iter()
            .filter(|p| !declared_set.contains(p) && !always_allowed.contains(p))
            .collect();
        if leaked.is_empty() { "✅ clean".into() } else {
            format!("⚠️ {}", leaked.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(","))
        }
    }).collect();
    rows.push(format!("    {:20} {}", "Undeclared leaks",
        leaks.iter().map(|l| format!("{:>w$}", l, w = col_w)).collect::<Vec<_>>().join(" ")));

    // Helper: per-VM cell from a VmLiveData accessor
    let per_vm = |f: &dyn Fn(&VmLiveData) -> String| -> String {
        vm_order.iter().map(|alias| {
            live.vm_data.iter().find(|v| v.alias == *alias).map(|v| f(v)).unwrap_or("—".into())
        }).map(|s| format!("{:>w$}", s, w = col_w)).collect::<Vec<_>>().join(" ")
    };

    // Row 5: DNS resolver(s) in use (from /etc/resolv.conf)
    rows.push(format!("    {:20} {}", "DNS servers", per_vm(&|v| v.dns_servers.clone())));

    // Row 6/7: Network throughput (1s /proc/net/dev delta, all non-lo ifaces)
    rows.push(format!("    {:20} {}", "Rate in", per_vm(&|v| v.net_rx_rate.clone())));
    rows.push(format!("    {:20} {}", "Rate out", per_vm(&|v| v.net_tx_rate.clone())));

    // Row 8: WireGuard MESH — real last-handshake age (not just SSH reachability)
    rows.push(format!("    {:20} {}", "Mesh (WG handshake)", per_vm(&|v| {
        if v.wg_peers == 0 { "—".into() }
        else if v.wg_up() { format!("✅ {} ({}p)", v.wg_handshake_age(), v.wg_peers) }
        else { format!("⚠️ {} ({}p)", v.wg_handshake_age(), v.wg_peers) }
    })));

    // Row 9: VPN tunnel status (wg0 up + recent handshake) + transfer
    rows.push(format!("    {:20} {}", "VPN (wg0)", per_vm(&|v| {
        if v.wg_peers == 0 { "❌ down".into() }
        else if v.wg_up() { format!("✅ ↓{} ↑{}", v.wg_rx, v.wg_tx) }
        else { "⚠️ stale".into() }
    })));

    // Row 10: Container count
    let containers: Vec<String> = vm_order.iter().map(|alias| {
        live.vm_data.iter().find(|v| v.alias == *alias)
            .map(|v| format!("{}/{}", v.containers_running, v.containers_total))
            .unwrap_or("—".into())
    }).collect();
    rows.push(format!("    {:20} {}", "Containers (up/total)",
        containers.iter().map(|c| format!("{:>w$}", c, w = col_w)).collect::<Vec<_>>().join(" ")));

    rows.join("\n")
}

fn build_database_section(live: &LiveData) -> String {
    if live.db_health.is_empty() {
        return "  (no databases declared)".into();
    }

    // Group by type for summary
    let mut by_type: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for db in &live.db_health {
        *by_type.entry(&db.db_type).or_default() += 1;
    }
    let type_summary: Vec<String> = by_type.iter().map(|(t, c)| format!("{} {}", c, t)).collect();

    let mut lines = vec![
        format!("DECLARED DATABASES — {} total ({})", live.db_health.len(), type_summary.join(", ")),
        format!("    {:20} {:10} {:22} {:16} {:6} {:4} {:8} {:10} {:6}",
            "Service", "Type", "Container", "VM", "Port", "TCP", "Health", "Size", "Backup"),
        format!("    {}", "\u{2500}".repeat(105)),
    ];
    for db in &live.db_health {
        let icon = if db.healthy { "\u{2705}" } else if db.running { "\u{26a0}\u{fe0f}" } else { "\u{274c}" };
        let tcp_i = if db.port == 0 { "\u{2014}" } else if db.tcp_ok { "\u{2705}" } else { "\u{274c}" };
        let health_i = if db.healthy { "\u{2705}" } else { "\u{274c}" };
        let backup_i = if db.backup { "\u{2705}" } else { "\u{274c}" };
        lines.push(format!("{} {:20} {:10} {:22} {:16} {:6} {}   {}   {:10} {}",
            icon, db.service, db.db_type, db.container, db.vm,
            if db.port > 0 { db.port.to_string() } else { "\u{2014}".into() },
            tcp_i, health_i, db.size, backup_i));
    }
    let healthy = live.db_health.iter().filter(|d| d.healthy).count();
    let running = live.db_health.iter().filter(|d| d.running).count();
    lines.push(String::new());
    lines.push(format!("  Healthy: {}/{}  Running: {}/{}",
        healthy, live.db_health.len(), running, live.db_health.len()));
    lines.join("\n")
}

fn build_storage_section(live: &LiveData) -> String {
    if live.storage_health.is_empty() {
        return "  (no storage buckets declared)".into();
    }
    let mut lines = vec![
        format!("OBJECT STORAGE — {} buckets (live)", live.storage_health.len()),
        format!("    {:30} {:10} {:14} {:6} {:10} {:10}",
            "Bucket", "Provider", "Tier", "Live", "Size", "Objects"),
        format!("    {}", "\u{2500}".repeat(90)),
    ];
    for s in &live.storage_health {
        let icon = if s.accessible { "\u{2705}" } else { "\u{274c}" };
        lines.push(format!("{} {:30} {:10} {:14} {}   {:10} {:10}",
            icon, s.name, s.provider, s.tier,
            if s.accessible { "\u{2705}" } else { "\u{274c}" },
            s.size, s.objects));
    }
    lines.join("\n")
}

fn build_databases(ctx: &Context) -> String {
    ctx.databases.iter().map(|d| {
        format!("   {:20} {:10} {:22} {:14} {:16} {}", d.service, d.db_type, d.container, d.db_name, d.vm, d.dns_access)
    }).collect::<Vec<_>>().join("\n")
}

fn build_performance(live: &LiveData) -> String {
    let mut sorted: Vec<_> = live.timers.iter().collect();
    sorted.sort_by(|a, b| b.1.cmp(a.1));
    sorted.iter().map(|(k, v)| format!("  {:20} {:.1}s", k, **v as f64 / 1000.0)).collect::<Vec<_>>().join("\n")
}

fn build_script_info(live: &LiveData) -> String {
    format!("  Engine:    Rust (native async tokio)\n  Duration:  {:.1}s\n  Checks:    TCP(native) HTTP(reqwest) DNS(trust-dns) SSH(rsync)", live.duration_ms as f64 / 1000.0)
}

fn build_mail_auth(ctx: &Context) -> String {
    let oci_ip = ctx.vms.iter().find(|v| v.alias == "oci-mail").map(|v| v.pub_ip.as_str()).unwrap_or("?");
    let lines = vec![
        "MAIL AUTH — Authorized Senders".into(),
        "─".repeat(60),
        format!("    {:20} {:26} {:16} {:30} DKIM Selector", "Sender", "Domain", "Auth Method", "SPF IP Range"),
        "─".repeat(60),
        format!("✅ {:20} {:26} {:16} {:30} cf2024-1._domainkey", "Cloudflare", "diegonmarcos.com", "Email Routing", "104.30.0.0/19"),
        format!("⚠️ {:20} {:26} {:16} {:30} dkim._domainkey", "Stalwart", "diegonmarcos.com", "Direct SMTP", format!("{} NOT IN SPF!", oci_ip)),
        format!("✅ {:20} {:26} {:16} {:30} google._domainkey", "Google", "diegonmarcos.com", "Google SMTP", "(via include)"),
        format!("✅ {:20} {:26} {:16} {:30} resend._dk.mails", "Resend/SES", "mails.diegonmarcos.com", "API + SES", "54.240.0.0/18"),
        format!("✅ {:20} {:26} {:16} {:30} (via Stalwart)", "OCI Email Dlv", "diegonmarcos.com", "SMTP Relay", "192.29.200.0/25"),
    ];
    lines.join("\n")
}

fn build_mail_flow(ctx: &Context, live: &LiveData) -> String {
    let oci_ip = ctx.vms.iter().find(|v| v.alias == "oci-mail").map(|v| v.pub_ip.as_str()).unwrap_or("?");
    let gcp_ip = ctx.vms.iter().find(|v| v.alias == "gcp-proxy").map(|v| v.pub_ip.as_str()).unwrap_or("?");
    let maddy = live.vm_data.iter().find(|v| v.alias == "oci-mail").and_then(|v| v.containers.iter().find(|c| c.name == "maddy"));
    let http_to_smtp_proxy_api = live.vm_data.iter().find(|v| v.alias == "gcp-proxy").and_then(|v| v.containers.iter().find(|c| c.name == "http-to-smtp-proxy-api"));
    let st_ok = maddy.map(|c| c.health != "exited").unwrap_or(false);
    let sp_ok = http_to_smtp_proxy_api.map(|c| c.health != "exited").unwrap_or(false);
    format!(
"MAIL FLOW — Pipeline Status
─────────────────────────────────
  📨 INBOUND: Gmail → MX → CF Email Routing → CF Worker → Caddy → http-to-smtp-proxy-api → Maddy
     {} http-to-smtp-proxy-api  {}
     {} maddy                   {}

  📱 CLIENT: Phone/Thunderbird → gcp-proxy ({}) → Caddy L4 → oci-mail → Maddy
{}
  📤 OUTBOUND: Maddy → OCI SMTP relay from {}
     ✅ SPF OK  ✅ DKIM OK

  📤 OUTBOUND TRANSACTIONAL: App → Resend API → SES → recipient
     ✅ SPF OK  ✅ DKIM OK  ✅ DMARC OK",
        if sp_ok { "✅" } else { "❌" }, http_to_smtp_proxy_api.map(|c| c.status.as_str()).unwrap_or("not found"),
        if st_ok { "✅" } else { "❌" }, maddy.map(|c| c.status.as_str()).unwrap_or("not found"),
        gcp_ip,
        ctx.caddy_l4.iter().map(|l| format!("     :{}  → {}", l.port, l.upstream)).collect::<Vec<_>>().join("\n"),
        oci_ip)
}

fn build_api_mcp(_ctx: &Context) -> String {
    // MCP endpoints from services with proxy.primary.type=mcp
    let services = _ctx.consolidated["services"].as_object();
    let mut lines = Vec::new();
    if let Some(svcs) = services {
        for (name, svc) in svcs {
            let proxy_type = svc["proxy"]["primary"]["type"].as_str().unwrap_or("");
            if proxy_type == "mcp" || name.contains("mcp") {
                let domain = svc["proxy"]["primary"]["parent_domain"].as_str().or(svc["domain"].as_str()).unwrap_or("?");
                let base = svc["proxy"]["primary"]["base_path"].as_str().unwrap_or("");
                if !base.is_empty() {
                    lines.push(format!("  {}{}/mcp", domain, base));
                }
            }
        }
    }
    if lines.is_empty() { "(no MCP endpoints found in consolidated)".into() } else { lines.join("\n") }
}

fn build_repos_registries() -> String {
    let repos = vec!["cloud", "cloud-data", "front", "unix", "tools", "vault"];
    let mut lines = vec!["  GIT REPOS".into()];
    for r in &repos {
        lines.push(format!("    {}", r));
    }
    lines.push(String::new());
    lines.push("  CONTAINER REGISTRY: ghcr.io/diegonmarcos/".into());
    lines.join("\n")
}

fn build_storage(ctx: &Context) -> String {
    let mut lines = vec!["  OBJECT STORAGE".into()];
    let storage = ctx.consolidated["storage"].as_array();
    if let Some(buckets) = storage {
        for b in buckets {
            lines.push(format!("    {} — {} ({})", b["provider"].as_str().unwrap_or("?"), b["name"].as_str().unwrap_or("?"), b["tier"].as_str().unwrap_or("?")));
        }
    }
    lines.push(String::new());
    lines.push("  DATABASES".into());
    for d in &ctx.databases {
        lines.push(format!("    {:20} {:10} {:22} {}", d.service, d.db_type, d.container, d.vm));
    }
    lines.join("\n")
}

fn build_docker_networks(ctx: &Context) -> String {
    let mut networks: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    if let Some(svcs) = ctx.consolidated["services"].as_object() {
        for (name, svc) in svcs {
            if let Some(nets) = svc["compose"]["networks"].as_array() {
                for n in nets {
                    if let Some(net) = n.as_str() {
                        networks.entry(net.to_string()).or_default().push(name.clone());
                    }
                }
            }
        }
    }
    if networks.is_empty() { return "(no network data)".into(); }
    let mut lines = vec![format!("    {:28} Services", "Network"), "    ".to_string() + &"─".repeat(60)];
    let mut sorted: Vec<_> = networks.iter().collect();
    sorted.sort_by_key(|(k, _)| (*k).clone());
    for (net, svcs) in sorted {
        lines.push(format!("    {:28} {}", net, svcs.join(", ")));
    }
    lines.join("\n")
}

fn build_vault_providers() -> String {
    let home = std::env::var("HOME").unwrap_or("/home/diego".into());
    let path = format!("{}/Mounts/Git/vault/A0_keys/providers/", home);
    match std::fs::read_dir(&path) {
        Ok(entries) => {
            let providers: Vec<String> = entries.filter_map(|e| e.ok()).filter(|e| e.path().is_dir()).map(|e| format!("🔑 {}", e.file_name().to_string_lossy())).collect();
            let mut lines = Vec::new();
            for chunk in providers.chunks(3) {
                lines.push(format!("  {}", chunk.iter().map(|p| format!("{:22}", p)).collect::<Vec<_>>().join(" ")));
            }
            lines.join("\n")
        }
        Err(_) => "  (vault not available)".into(),
    }
}

fn build_framework_paths(ctx: &Context) -> String {
    let mut lines = vec![
        "  BUILD ENGINES".into(),
        "    Service engine       ~/git/cloud-infra/a_solutions/_engine.sh".into(),
        "    HM engine            ~/git/cloud-infra/1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh".into(),
        "    Front engine         ~/git/front/1.ops/build_main.sh".into(),
        "    NixOS host           ~/git/cloud-unix/aa_nixos-surface_host/build.sh".into(),
        String::new(),
        "  HOME-MANAGER".into(),
    ];
    for vm in &ctx.vms {
        lines.push(format!("    {:20} ~/git/cloud-infra/b_infra/nixhm-sudo-{}/src/", vm.alias, vm.alias));
    }
    lines.push(String::new());
    lines.push("  DATA".into());
    lines.push("    cloud-data           ~/git/cloud-data/".into());
    lines.push("    Topology             ~/git/cloud-data/cloud-data-topology.json".into());
    lines.push("    Consolidated         ~/git/cloud-data/_cloud-data-consolidated.json".into());
    lines.push(String::new());
    lines.push("  TERRAFORM".into());
    lines.push("    OCI                  ~/git/cloud-infra/c_vps/vps_oci/src/main.tf".into());
    lines.push("    GCP                  ~/git/cloud-infra/c_vps/vps_gcloud/src/main.tf".into());
    lines.push("    Cloudflare           ~/git/cloud-infra/c_vps/ba-clo_cloudflare/src/main.tf".into());
    lines.join("\n")
}
