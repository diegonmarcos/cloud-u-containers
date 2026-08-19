use crate::types::*;
use anyhow::Result;
use reports_common::context::find_cloud_data_file;
use std::collections::HashMap;
use std::path::PathBuf;

pub struct Context {
    pub monitoring: MonitoringTargets,
    pub databases: DatabasesJson,
    pub manifests: HashMap<String, VmContainerManifest>,
    pub cloud_buckets: Vec<CloudBucket>,
    pub services: Vec<ServiceEntry>,
    pub mcp_servers: Vec<McpServer>,
    pub vps_providers: Vec<VpsProvider>,
    pub vm_finops: Vec<VmFinops>,
    pub total_domains: usize,
    pub ai: Option<AiSummary>,
    pub firewalls: Vec<VmFirewall>,
    pub global_firewall: GlobalFirewall,
}

pub fn load_context() -> Result<Context> {
    // Migration to the new pattern: build-reports.json is the engine-derived
    // single source for endpoints/tls/dns/vms (cloud/2_configs/dist + relative
    // symlink in cloud-data/). Legacy cloud-data-monitoring-targets.json was
    // routed to z_archive/ and shipped stale entries (windmill, postlite,
    // quant-lab-*, plus URL pollution). Try the new file first; fall back to
    // the legacy name only if the engine hasn't been run with the new deriver.
    let monitoring: MonitoringTargets = match find_cloud_data_file("build-reports.json")
        .or_else(|| find_cloud_data_file("cloud-data-monitoring-targets.json"))
    {
        Some(p) => serde_json::from_str(&std::fs::read_to_string(p)?)?,
        None => MonitoringTargets {
            endpoint_checks: vec![],
            tls_checks: vec![],
            vms: vec![
                VmTarget { ip: "10.0.0.1".into(), name: "gcp-proxy".into(), user: "diego".into() },
                VmTarget { ip: "10.0.0.3".into(), name: "oci-mail".into(), user: "ubuntu".into() },
                VmTarget { ip: "10.0.0.4".into(), name: "oci-analytics".into(), user: "ubuntu".into() },
                VmTarget { ip: "10.0.0.6".into(), name: "oci-apps".into(), user: "ubuntu".into() },
            ],
        },
    };

    // Migrated to build-reports.json:.databases (single derived file).
    // Falls through to legacy cloud-data-databases.json for back-compat.
    let databases: DatabasesJson = if let Some(arr) = reports_common::context::load_build_reports_section("databases") {
        DatabasesJson { databases: serde_json::from_value(arr).unwrap_or_default() }
    } else if let Some(p) = find_cloud_data_file("cloud-data-databases.json") {
        serde_json::from_str(&std::fs::read_to_string(p)?)?
    } else {
        DatabasesJson { databases: vec![] }
    };

    let consolidated_path = find_cloud_data_file("_cloud-data-consolidated.json");
    // Load cloud buckets + services from consolidated JSON
    let (cloud_buckets, services, vps_providers, vm_finops, total_domains, firewalls, global_firewall) = if let Some(cp) = consolidated_path.as_ref() {
        match std::fs::read_to_string(cp) {
            Ok(raw) => match serde_json::from_str::<ConsolidatedJson>(&raw) {
                Ok(c) => {
                    let svc_list: Vec<ServiceEntry> = c.services.iter().map(|(name, svc)| {
                        let stype = if name.contains("mcp") { "mcp" }
                            else if ["caddy","introspect-proxy","hickory-dns","redis","db-agent","fluent-bit"].contains(&name.as_str()) { "infra" }
                            else { "app" };
                        let domain = svc["domain"].as_str().unwrap_or("").to_string();
                        let port = svc["port"].as_u64().unwrap_or(0) as u16;
                        // API classification from consolidated (derived by cloud-data-config-consolidated.ts)
                        let api_info = &svc["api"];
                        let has_api_declared = api_info["has_api"].as_bool().unwrap_or(false);
                        let has_web_ui = api_info["has_web_ui"].as_bool().unwrap_or(!domain.is_empty());
                        let api_path = api_info["api_path"].as_str().unwrap_or("").to_string();
                        let api_url = api_info["api_url"].as_str().unwrap_or("").to_string();
                        // has_api starts from declared, then upgraded to true by runtime probing in main.rs
                        let has_api = has_api_declared;
                        // Routed at its domain iff it declares a Caddy primary proxy or an
                        // app/mail hub. Headless services (e.g. mail-puller) carry a `domain`
                        // for identity but have no route → must not be HTTP-probed.
                        let proxy = &svc["proxy"];
                        let serves_http = proxy["primary"].is_object()
                            || proxy["app_hub"].as_bool().unwrap_or(false)
                            || proxy["mail_hub"].as_bool().unwrap_or(false);
                        ServiceEntry {
                            name: name.clone(),
                            category: svc["category"].as_str().unwrap_or("?").to_string(),
                            vm: svc["vm"].as_str().unwrap_or("?").to_string(),
                            domain,
                            enabled: svc["enabled"].as_bool().unwrap_or(true),
                            containers: svc["containers"].as_object().map(|o| o.len() as u32).unwrap_or(0),
                            port: svc["port"].as_u64().unwrap_or(0) as u16,
                            service_type: stype.to_string(),
                            has_api,
                            has_web_ui,
                            api_path,
                            api_url,
                            serves_http,
                        }
                    }).collect();
                    // Parse VPS providers
                    let vps_list: Vec<VpsProvider> = c.vpss.iter().map(|(name, v)| {
                        VpsProvider {
                            name: name.clone(),
                            provider: v["provider"].as_str().unwrap_or(name).to_string(),
                            tier: v["tier"].as_str().unwrap_or("?").to_string(),
                        }
                    }).collect();

                    // Parse VM finops
                    let vm_fin: Vec<VmFinops> = c.vms.iter().map(|(vm_id, vm)| {
                        let provider = if vm_id.starts_with("oci") { "OCI" }
                            else if vm_id.starts_with("gcp") { "GCP" }
                            else { "?" };
                        let tier = if vm_id.contains("-f_") || vm_id.contains("-f-") { "Free" } else { "Paid" };
                        let specs = &vm["specs"];
                        VmFinops {
                            alias: vm["ssh_alias"].as_str().unwrap_or(vm_id).to_string(),
                            provider: provider.to_string(),
                            tier: tier.to_string(),
                            cpu: specs["cpu"].as_u64().unwrap_or(0) as u32,
                            ram_gb: specs["ram_gb"].as_f64().unwrap_or(0.0),
                            shape: specs["shape"].as_str()
                                .or(specs["machine_type"].as_str())
                                .unwrap_or("?").to_string(),
                            services: vm["services"].as_array().map(|a| a.len() as u32).unwrap_or(0),
                            containers: vm["container_count"].as_u64().unwrap_or(0) as u32,
                        }
                    }).collect();

                    // Count unique domains
                    let total_domains = svc_list.iter()
                        .filter(|s| s.enabled && !s.domain.is_empty())
                        .map(|s| s.domain.clone())
                        .collect::<std::collections::HashSet<_>>()
                        .len();

                    // Parse firewalls
                    let gfw = {
                        let g = &c.firewalls["global"];
                        GlobalFirewall {
                            docker_iptables: g["docker_iptables"].as_bool().unwrap_or(false),
                            forward_policy: g["forward_policy"].as_str().unwrap_or("?").to_string(),
                            docker_subnet: g["docker_subnet"].as_str().unwrap_or("?").to_string(),
                            wg_subnet: g["wg_subnet"].as_str().unwrap_or("?").to_string(),
                        }
                    };

                    let fw_os = c.firewalls["os"].as_object();
                    let mut fw_list = Vec::new();
                    for (vm_id, vm) in c.vms.iter() {
                        let alias = vm["ssh_alias"].as_str().unwrap_or(vm_id);
                        let pub_ports: Vec<FirewallRule> = vm["public_ports"].as_array()
                            .map(|arr| arr.iter().map(|p| FirewallRule {
                                port: p["port"].as_u64().unwrap_or(0) as u16,
                                proto: p["proto"].as_str().unwrap_or("tcp").to_string(),
                                desc: p["desc"].as_str().unwrap_or("").to_string(),
                            }).collect())
                            .unwrap_or_default();
                        let os_rules: Vec<FirewallRule> = fw_os
                            .and_then(|m| m.get(alias))
                            .and_then(|v| v.as_array())
                            .map(|arr| arr.iter().map(|r| FirewallRule {
                                port: r["port"].as_u64().unwrap_or(0) as u16,
                                proto: r["proto"].as_str().unwrap_or("tcp").to_string(),
                                desc: r["desc"].as_str().unwrap_or("").to_string(),
                            }).collect())
                            .unwrap_or_default();
                        let wg_only = pub_ports.is_empty();
                        fw_list.push(VmFirewall {
                            vm_name: alias.to_string(),
                            public_ports: pub_ports,
                            os_rules,
                            wg_only,
                        });
                    }
                    fw_list.sort_by(|a, b| a.vm_name.cmp(&b.vm_name));

                    (c.storage, svc_list, vps_list, vm_fin, total_domains, fw_list, gfw)
                }
                Err(e) => { eprintln!("  Failed to parse consolidated: {}", e); (vec![], vec![], vec![], vec![], 0, vec![], GlobalFirewall::default()) }
            },
            Err(_) => (vec![], vec![], vec![], vec![], 0, vec![], GlobalFirewall::default()),
        }
    } else {
        (vec![], vec![], vec![], vec![], 0, vec![], GlobalFirewall::default())
    };

    // Load per-VM container manifests
    let mut manifests = HashMap::new();
    for vm in &monitoring.vms {
        let manifest_name = format!("cloud-data-containers-{}.json", vm.name);
        if let Some(manifest_path) = find_cloud_data_file(&manifest_name) {
            match std::fs::read_to_string(&manifest_path) {
                Ok(raw) => match serde_json::from_str::<VmContainerManifest>(&raw) {
                    Ok(manifest) => {
                        eprintln!("  Loaded manifest for {} ({} services)", vm.name, manifest.services.len());
                        manifests.insert(vm.name.clone(), manifest);
                    }
                    Err(e) => eprintln!("  Failed to parse manifest for {}: {}", vm.name, e),
                },
                Err(e) => eprintln!("  Failed to read manifest for {}: {}", vm.name, e),
            }
        }
    }

    // Load MCP servers from .mcp.json (actual configured MCPs)
    let mcp_servers = {
        let home = std::env::var("HOME").unwrap_or("/home/diego".into());
        let mcp_paths = [
            format!("{}/.mcp.json", home),
            format!("{}/.claude/.mcp.json", home),
        ];
        let mut servers = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for mcp_path in &mcp_paths {
            if let Ok(raw) = std::fs::read_to_string(mcp_path) {
                if let Ok(j) = serde_json::from_str::<serde_json::Value>(&raw) {
                    if let Some(mcps) = j["mcpServers"].as_object() {
                        for (name, cfg) in mcps {
                            if seen.contains(name) { continue; }
                            seen.insert(name.clone());
                            let command = cfg["command"].as_str().unwrap_or("?").to_string();
                            let args: Vec<String> = cfg["args"].as_array()
                                .map(|a| a.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
                                .unwrap_or_default();
                            let source_path = args.first().cloned().unwrap_or_default();
                            let transport = if args.iter().any(|a| a.contains("http")) { "http" } else { "stdio" };
                            servers.push(McpServer {
                                name: name.clone(),
                                command,
                                source_path,
                                transport: transport.to_string(),
                            });
                        }
                    }
                }
            }
        }
        servers.sort_by(|a, b| a.name.cmp(&b.name));
        servers
    };

    // Load AI usage data from Claude stats-cache.json
    let ai = load_ai_summary();

    Ok(Context { monitoring, databases, manifests, cloud_buckets, services, mcp_servers, vps_providers, vm_finops, total_domains, ai, firewalls, global_firewall })
}

// ── AI pricing per 1M tokens ────────────────────────────────────────

struct ModelPricing {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_create: f64,
}

fn pricing_for(model: &str) -> ModelPricing {
    if model.contains("haiku") {
        ModelPricing { input: 0.80, output: 4.00, cache_read: 0.08, cache_create: 1.00 }
    } else if model.contains("sonnet") {
        ModelPricing { input: 3.00, output: 15.00, cache_read: 0.30, cache_create: 3.75 }
    } else {
        // opus (all versions)
        ModelPricing { input: 15.00, output: 75.00, cache_read: 1.50, cache_create: 18.75 }
    }
}

fn normalize_model_name(raw: &str) -> String {
    if raw.contains("opus-4-6") || raw.contains("opus_4_6") {
        "opus-4.6".into()
    } else if raw.contains("opus-4-5") || raw.contains("opus_4_5") {
        "opus-4.5".into()
    } else if raw.contains("sonnet-4-5") || raw.contains("sonnet_4_5") {
        "sonnet-4.5".into()
    } else if raw.contains("haiku-4-5") || raw.contains("haiku_4_5") {
        "haiku-4.5".into()
    } else {
        raw.to_string()
    }
}

fn load_ai_summary() -> Option<AiSummary> {
    let home = std::env::var("HOME").unwrap_or("/home/diego".into());
    let stats_path = PathBuf::from(&home).join(".claude/stats-cache.json");
    if !stats_path.exists() {
        eprintln!("  AI stats not found at {}", stats_path.display());
        return None;
    }

    let raw = std::fs::read_to_string(&stats_path).ok()?;
    let j: serde_json::Value = serde_json::from_str(&raw).ok()?;

    // Parse model usage
    let mut models = Vec::new();
    if let Some(mu) = j["modelUsage"].as_object() {
        for (raw_name, usage) in mu {
            let input = usage["inputTokens"].as_u64().unwrap_or(0);
            let output = usage["outputTokens"].as_u64().unwrap_or(0);
            let cache_read = usage["cacheReadInputTokens"].as_u64().unwrap_or(0);
            let cache_create = usage["cacheCreationInputTokens"].as_u64().unwrap_or(0);

            let p = pricing_for(raw_name);
            let cost = (input as f64 * p.input
                + output as f64 * p.output
                + cache_read as f64 * p.cache_read
                + cache_create as f64 * p.cache_create)
                / 1_000_000.0;

            models.push(AiModelUsage {
                model: normalize_model_name(raw_name),
                input_tokens: input,
                output_tokens: output,
                cache_read_tokens: cache_read,
                cache_create_tokens: cache_create,
                estimated_cost_usd: cost,
            });
        }
    }
    // Sort by cost descending
    models.sort_by(|a, b| b.estimated_cost_usd.partial_cmp(&a.estimated_cost_usd).unwrap_or(std::cmp::Ordering::Equal));

    // Parse daily activity (last 7 days)
    let mut daily = Vec::new();
    if let Some(da) = j["dailyActivity"].as_array() {
        let dmt: HashMap<String, u64> = j["dailyModelTokens"].as_array()
            .map(|arr| {
                arr.iter().filter_map(|entry| {
                    let date = entry["date"].as_str()?;
                    let total: u64 = entry["tokensByModel"].as_object()?
                        .values()
                        .filter_map(|v| v.as_u64())
                        .sum();
                    Some((date.to_string(), total))
                }).collect()
            })
            .unwrap_or_default();

        // Take last 7 entries
        let start = if da.len() > 7 { da.len() - 7 } else { 0 };
        for entry in &da[start..] {
            let date = entry["date"].as_str().unwrap_or("").to_string();
            let tokens = dmt.get(&date).copied().unwrap_or(0);
            daily.push(AiDailyActivity {
                date: date.clone(),
                messages: entry["messageCount"].as_u64().unwrap_or(0),
                sessions: entry["sessionCount"].as_u64().unwrap_or(0),
                tool_calls: entry["toolCallCount"].as_u64().unwrap_or(0),
                tokens,
            });
        }
    }

    let total_sessions = j["totalSessions"].as_u64().unwrap_or(0);
    let total_messages = j["totalMessages"].as_u64().unwrap_or(0);
    let first_session = j["firstSessionDate"].as_str().unwrap_or("").to_string();
    let total_cost: f64 = models.iter().map(|m| m.estimated_cost_usd).sum();

    eprintln!("  AI stats loaded: {} models, {} daily entries, ${:.2} est. total", models.len(), daily.len(), total_cost);

    Some(AiSummary {
        models,
        daily,
        total_sessions,
        total_messages,
        total_cost_usd: total_cost,
        first_session,
    })
}
