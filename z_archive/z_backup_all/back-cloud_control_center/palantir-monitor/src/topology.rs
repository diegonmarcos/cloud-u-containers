use crate::config::CloudConfig;

pub fn generate_ascii_topology(config: &CloudConfig) -> String {
    let mut output = String::new();

    output.push_str("```\n");
    output.push_str("┌────────────────────────────────────────────────────────────────────────┐\n");
    output.push_str("│                    CLOUD INFRASTRUCTURE TOPOLOGY                       │\n");
    output.push_str("└────────────────────────────────────────────────────────────────────────┘\n");
    output.push_str("\n");
    output.push_str("Internet\n");
    output.push_str("    │\n");
    output.push_str("    ├── Cloudflare DNS (proxy)\n");
    output.push_str("    │       ├── analytics.diegonmarcos.com → 172.67.168.34\n");
    output.push_str("    │       ├── proxy.diegonmarcos.com → 172.67.168.34\n");
    output.push_str("    │       ├── auth.diegonmarcos.com → 104.21.46.63\n");
    output.push_str("    │       └── cloud.diegonmarcos.com → 104.21.46.63\n");
    output.push_str("    │\n");
    output.push_str("    ├── OCI eu-marseille-1 ─────────────────────────────────────────┐\n");
    output.push_str("    │   │                                                            │\n");

    // OCI Micro 1
    if let Some(vm) = config.vms.iter().find(|v| v.id == "oci-f-micro_1") {
        output.push_str(&format!("    │   ├─ [{}] {} ({})\n", vm.id, vm.ip, vm.ram));
        output.push_str(&format!("    │   │   Role: {}\n", vm.role));
        if let Some(net) = config.networks.iter().find(|n| n.vm == vm.id) {
            output.push_str(&format!("    │   │   Network: {} ({})\n", net.name, net.subnet));
        }
        output.push_str(&format!("    │   │   Services: {}\n", vm.services.join(", ")));
        output.push_str("    │   │   Ports: 22, 80, 443, 465, 993, 8080\n");
        output.push_str("    │   │\n");
    }

    // OCI Micro 2
    if let Some(vm) = config.vms.iter().find(|v| v.id == "oci-f-micro_2") {
        output.push_str(&format!("    │   ├─ [{}] {} ({})\n", vm.id, vm.ip, vm.ram));
        output.push_str(&format!("    │   │   Role: {}\n", vm.role));
        if let Some(net) = config.networks.iter().find(|n| n.vm == vm.id) {
            output.push_str(&format!("    │   │   Network: {} ({})\n", net.name, net.subnet));
        }
        output.push_str(&format!("    │   │   Services: {}\n", vm.services.join(", ")));
        output.push_str("    │   │   Ports: 22, 80, 443\n");
        output.push_str("    │   │\n");
    }

    // OCI Flex 1
    if let Some(vm) = config.vms.iter().find(|v| v.id == "oci-p-flex_1") {
        output.push_str(&format!("    │   └─ [{}] {} ({}) [SLEEPING]\n", vm.id, vm.ip, vm.ram));
        output.push_str(&format!("    │       Role: {} ({})\n", vm.role, vm.mode.as_ref().unwrap_or(&"".to_string())));
        if let Some(net) = config.networks.iter().find(|n| n.vm == vm.id) {
            output.push_str(&format!("    │       Network: {} ({})\n", net.name, net.subnet));
        }
        output.push_str(&format!("    │       Services: {}\n", vm.services.join(", ")));
        output.push_str("    │       Ports: 22, 80, 443, 5232, 8384\n");
        output.push_str("    │\n");
    }

    output.push_str("    └── GCP us-central1 ────────────────────────────────────────────┘\n");
    output.push_str("        │\n");

    // GCP Micro 1
    if let Some(vm) = config.vms.iter().find(|v| v.id == "gcp-f-micro_1") {
        output.push_str(&format!("        └─ [{}] {} ({})\n", vm.id, vm.ip, vm.ram));
        output.push_str(&format!("            Role: {}\n", vm.role));
        if let Some(net) = config.networks.iter().find(|n| n.vm == vm.id) {
            output.push_str(&format!("            Network: {} ({})\n", net.name, net.subnet));
        }
        output.push_str(&format!("            Services: {}\n", vm.services.join(", ")));
        output.push_str("            Ports: 22, 80, 81, 443\n");
    }

    output.push_str("\n");
    output.push_str("Docker Networks Summary:\n");
    for net in &config.networks {
        let status = if net.vm == "oci-p-flex_1" { " (sleeping)" } else { "" };
        output.push_str(&format!("  • {} ({}) → {}{}\n", net.name, net.subnet, net.vm, status));
    }

    output.push_str("```\n");

    output
}
