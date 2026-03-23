// gen-topology.ts — Generate cloud-data-topology.json + cloud-data-topology.md
//
// Sources:
//   ~/.ssh/config                            → VM aliases + WireGuard IPs
//   a_solutions/{service}/build.json         → service metadata
//   a_solutions/{service}/dist/compose.yml   → containers, ports, networks
//   b_infra/home-manager/                    → WireGuard peers
//   ba-clo_hickory-dns/dist/zones/           → DNS records
//
// Outputs (written directly to cloud-data/ submodule, symlinked from repo root):
//   cloud-data/cloud-data-topology.json  → machine-readable infrastructure topology
//   cloud-data/cloud-data-topology.md    → human-readable tables (via Nunjucks)

import { readFileSync, writeFileSync, existsSync } from "fs";
import { resolve, join } from "path";
import { homedir } from "os";
import nunjucks from "nunjucks";
import { scanBuildJsons, CATEGORY_PREFIX } from "./parsers/build-json.js";
import { parseCompose } from "./parsers/compose.js";
import { parseSSHConfig } from "./parsers/ssh-config.js";
import { parseDNSZones } from "./parsers/dns.js";
import { parseWireGuard, parseOSFirewalls, parseOSFirewallGlobal, type OSFirewall, type OSFirewallGlobal } from "./parsers/wireguard.js";
import { parseTerraform, type FirewallData } from "./parsers/terraform.js";

// --- Paths ----------------------------------------------------------------

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT_DEFAULT = resolve(ENGINE_DIR, "../../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT_DEFAULT, "..");
const CLOUD_ROOT = process.env.GIT_BASE ? join(GIT_BASE, "cloud") : CLOUD_ROOT_DEFAULT;
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const TEMPLATE_DIR = join(ENGINE_DIR, "templates");
const SSH_CONFIG = join(homedir(), ".ssh", "config");

const CLOUD_DATA_DIR = join(CLOUD_ROOT, "cloud-data");
const OUTPUT_JSON = join(CLOUD_DATA_DIR, "cloud-data-topology.json");
const OUTPUT_MD = join(CLOUD_DATA_DIR, "cloud-data-topology.md");

// --- Types ----------------------------------------------------------------

interface VMSpecs {
  cpu: number;
  ram_gb: number;
  disk_gb: number;
  shape?: string;
  machine_type?: string;
  gpu?: string;
  gpu_vram?: string;
}

interface VM {
  ip: string;
  wg_ip: string;
  user: string;
  method: string;
  ssh_alias: string;
  description: string;
  containers: string[];
  ports: string[];
  networks: string[];
  specs?: VMSpecs;
  [key: string]: unknown;
}

interface Service {
  category: string;
  vm: string;
  containers: string[];
  description: string;
  domain?: string;
  flake?: string;
  ports?: string[];
  networks?: string[];
  // Declarative infrastructure fields (from build.json)
  proxy?: import("./parsers/build-json.js").ProxyConfig;
  health?: import("./parsers/build-json.js").HealthConfig;
  monitoring?: import("./parsers/build-json.js").MonitoringConfig;
  backup?: import("./parsers/build-json.js").BackupConfig;
  notifications?: import("./parsers/build-json.js").NotificationsConfig;
  declared_ports?: Record<string, import("./parsers/build-json.js").PortConfig>;
  [key: string]: unknown;
}

interface CloudTopology {
  ssh_key: string;
  remote_base: string;
  vms: Record<string, VM>;
  vpss: Record<string, unknown>;
  storage: Array<{ provider: string; name: string; tier: string }>;
  firewalls: FirewallData[];
  os_firewalls: OSFirewall[];
  os_firewall_global: OSFirewallGlobal;
  wireguard: { peers: Array<{ name: string; wg_ip: string; endpoint: string; role: string; port?: number }> };
  dns: { zones: Array<{ name: string; records: Array<{ name: string; type: string; value: string; comment?: string }> }> };
  services: Record<string, Service>;
}

// --- Main -----------------------------------------------------------------

function main() {
  console.log("gen-topology: scanning sources...");

  // 1. Load existing config to preserve manual fields
  const existingPath = existsSync(OUTPUT_JSON)
    ? OUTPUT_JSON
    : join(CLOUD_ROOT, "config.json"); // fallback to old name
  let existing: any = null;
  if (existsSync(existingPath)) {
    existing = JSON.parse(readFileSync(existingPath, "utf-8"));
  }

  // 2. Parse SSH config for VM data
  const sshHosts = parseSSHConfig(SSH_CONFIG);
  const aliasToVmId = loadExistingVMMap(existing);
  console.log(
    `  SSH config: ${sshHosts.filter((h) => !h.commented).length} active hosts, ${sshHosts.filter((h) => h.commented).length} commented`
  );

  // 3. Build VMs from SSH config
  const vms: Record<string, VM> = {};
  for (const host of sshHosts) {
    if (host.commented) continue;
    const vmId = aliasToVmId[host.alias];
    if (!vmId) {
      console.warn(`  WARN: SSH alias '${host.alias}' not mapped to a VM ID — skipping`);
      continue;
    }

    const existingVm = existing?.vms?.[vmId];
    vms[vmId] = {
      ...existingVm,
      ip: existingVm?.ip || host.hostname,
      wg_ip: existingVm?.wg_ip || host.hostname,
      user: host.user,
      method: existingVm?.method || "key",
      ssh_alias: host.alias,
      description: existingVm?.description || "",
      containers: [],
      ports: [],
      networks: [],
    } as VM;
  }

  // Preserve VMs from existing config not in SSH
  if (existing?.vms) {
    for (const [vmId, vm] of Object.entries(existing.vms) as [string, any][]) {
      if (!vms[vmId]) {
        vms[vmId] = { ...vm, containers: vm.containers || [], ports: vm.ports || [], networks: vm.networks || [] };
      }
    }
  }

  // 4. Scan build.json files
  const buildEntries = scanBuildJsons(SOLUTIONS_DIR);
  console.log(`  build.json: ${buildEntries.length} services found`);

  // 5. Build services map with compose data
  const services: Record<string, Service> = {};

  for (const entry of buildEntries) {
    const compose = parseCompose(SOLUTIONS_DIR, entry.folder, entry.name);
    const vmId = resolveVmId(entry.vm, aliasToVmId, vms);
    const existingSvc = existing?.services?.[entry.name];

    const svc: Service = {
      category: entry.category,
      vm: vmId,
      containers: compose.containers.length > 0 ? compose.containers : existingSvc?.containers || [],
      description: entry.description || existingSvc?.description || "",
      ...(entry.domain ? { domain: entry.domain } : existingSvc?.domain ? { domain: existingSvc.domain } : {}),
      ...(entry.flake ? { flake: entry.flake } : existingSvc?.flake ? { flake: existingSvc.flake } : {}),
      ...(compose.ports.length > 0 ? { ports: compose.ports } : existingSvc?.ports ? { ports: existingSvc.ports } : {}),
      ...(compose.networks.length > 0 ? { networks: compose.networks } : existingSvc?.networks ? { networks: existingSvc.networks } : {}),
      // Declarative infrastructure fields (pass through from build.json)
      ...(entry.proxy ? { proxy: entry.proxy } : {}),
      ...(entry.ports ? { declared_ports: entry.ports } : {}),
      ...(entry.health ? { health: entry.health } : {}),
      ...(entry.monitoring ? { monitoring: entry.monitoring } : {}),
      ...(entry.backup ? { backup: entry.backup } : {}),
      ...(entry.notifications ? { notifications: entry.notifications } : {}),
    };

    // Preserve extra fields from existing
    if (existingSvc) {
      for (const [k, v] of Object.entries(existingSvc)) {
        if (!(k in svc)) (svc as any)[k] = v;
      }
    }

    services[entry.name] = svc;
  }

  // Preserve existing services not covered by build.json
  if (existing?.services) {
    for (const [name, svc] of Object.entries(existing.services) as [string, any][]) {
      if (!services[name]) services[name] = svc;
    }
  }

  // 6. Aggregate containers/ports/networks into VMs
  for (const [, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm) continue;
    if (svc.containers) {
      for (const c of svc.containers) {
        if (!vm.containers.includes(c)) vm.containers.push(c);
      }
    }
    if (svc.ports) {
      for (const p of svc.ports) {
        if (!vm.ports.includes(p)) vm.ports.push(p);
      }
    }
    if (svc.networks) {
      for (const n of svc.networks) {
        if (!vm.networks.includes(n)) vm.networks.push(n);
      }
    }
  }

  // 7. Parse WireGuard peers
  const wgPeers = parseWireGuard(GIT_BASE);
  // Also build peers from VM data if WG parser found nothing
  if (wgPeers.length === 0) {
    for (const [, vm] of Object.entries(vms)) {
      if (vm.wg_ip) {
        wgPeers.push({
          name: vm.ssh_alias,
          wg_ip: vm.wg_ip,
          endpoint: vm.ip ? `${vm.ip}:51820` : "dynamic",
          role: vm.ssh_alias === "gcp-proxy" ? "hub" : "spoke",
        });
      }
    }
  }

  // 8. Parse DNS zones
  const dnsZones = parseDNSZones(SOLUTIONS_DIR);

  // 9. Parse Terraform for VM specs + storage
  const tfData = parseTerraform(join(CLOUD_ROOT, "b_infra"));
  const totalFwRules = tfData.firewalls.reduce((sum, fw) => sum + fw.rules.length, 0);
  console.log(
    `  Terraform: ${Object.keys(tfData.vm_specs).length} VM specs, ${tfData.storage.length} storage buckets, ${tfData.providers.length} providers, ${totalFwRules} firewall rules`
  );

  // Map terraform instance names → VM IDs
  // OCI: display_name matches VM ID directly (e.g. "oci-E2-f_0")
  // GCP: instance name (e.g. "arch-1") needs mapping via gcloud_instance field
  const tfNameToVmId: Record<string, string> = {};

  // Build reverse map: gcloud_instance name → VM ID
  for (const [vmId, vm] of Object.entries(vms)) {
    const gcName = (vm as any).gcloud_instance;
    if (gcName) tfNameToVmId[gcName] = vmId;
  }
  // Also check existing (for VMs not in SSH config)
  if (existing?.vms) {
    for (const [vmId, vm] of Object.entries(existing.vms) as [string, any][]) {
      if (vm.gcloud_instance && !tfNameToVmId[vm.gcloud_instance]) {
        tfNameToVmId[vm.gcloud_instance] = vmId;
      }
    }
  }

  // Inject specs into VMs
  for (const [tfName, specs] of Object.entries(tfData.vm_specs)) {
    const vmId = tfNameToVmId[tfName];
    if (vmId && vms[vmId]) {
      vms[vmId].specs = specs;
    } else if (vms[tfName]) {
      // Direct match (OCI case — display_name IS the VM ID)
      vms[tfName].specs = specs;
    }
  }

  // Update vpss from terraform providers (merge, don't overwrite)
  const vpss: Record<string, unknown> = existing?.vpss ? { ...existing.vpss } : {};
  for (const prov of tfData.providers) {
    const existingVps = (vpss[prov.name] as any) || {};
    vpss[prov.name] = {
      ...existingVps,
      has_terraform: prov.has_terraform,
      folder: `b_infra/${prov.folder}`,
    };
  }

  // 10. Parse OS-level firewalls from home-manager
  const osFirewalls = parseOSFirewalls(GIT_BASE);
  const totalOsRules = osFirewalls.reduce((sum, fw) => sum + fw.rules.length, 0);
  console.log(
    `  OS Firewalls: ${osFirewalls.length} VMs, ${totalOsRules} port rules`
  );

  // 10b. Parse global firewall policy (FORWARD, NAT, docker iptables:false)
  const osFirewallGlobal = parseOSFirewallGlobal(GIT_BASE);
  console.log(
    `  Firewall global: docker_iptables=${osFirewallGlobal.docker_iptables}, ${osFirewallGlobal.forward_rules.length} FORWARD rules, ${osFirewallGlobal.nat_rules.length} NAT rules`
  );

  // 11. Assemble topology
  const topology: CloudTopology = {
    ssh_key: existing?.ssh_key || detectSSHKey(),
    remote_base: existing?.remote_base || "/opt/containers",
    vms,
    vpss,
    storage: tfData.storage,
    firewalls: tfData.firewalls,
    os_firewalls: osFirewalls,
    os_firewall_global: osFirewallGlobal,
    wireguard: { peers: wgPeers },
    dns: { zones: dnsZones },
    services,
  };

  // Also keep native section if it existed
  if (existing?.native) {
    (topology as any).native = existing.native;
  }

  // 11. Write cloud-data-topology.json
  writeFileSync(OUTPUT_JSON, JSON.stringify(topology, null, 2) + "\n");
  console.log(`  Written: cloud-data-topology.json (${Object.keys(services).length} services, ${Object.keys(vms).length} VMs)`);

  // 12. Render cloud-topology.md
  const templatePath = join(TEMPLATE_DIR, "cloud-topology.md.njk");
  if (existsSync(templatePath)) {
    nunjucks.configure(TEMPLATE_DIR, { autoescape: false, trimBlocks: true, lstripBlocks: true });
    // Pre-group services by category for template
    const categoryLabels: Record<string, string> = {
      app: "Suite (aa-sui_*)", mic: "Misc (ab-mic_*)", fin: "Financial (ac-fin_*)",
      agi: "AI/Agents (ad-agi_*)", cloud: "Cloud Providers (ba-clo_*)",
      sec: "Security (bb-sec_*)", tools: "Observability (bc-obs_*)", data: "Data & Backups (ca-dat_*)",
    };
    const servicesByCategory: Record<string, string> = {};
    const servicesByCategoryData: Record<string, any[]> = {};
    for (const [catKey, catLabel] of Object.entries(categoryLabels)) {
      const svcs = Object.entries(services)
        .filter(([, s]) => s.category === catKey)
        .map(([name, s]) => {
          const prefix = CATEGORY_PREFIX[catKey] || "";
          return {
            name,
            flakeFolder: prefix + (s.flake || name),
            vmAlias: vms[s.vm]?.ssh_alias || s.vm,
            domain: s.domain,
            description: s.description,
          };
        });
      if (svcs.length > 0) {
        servicesByCategory[catKey] = catLabel;
        servicesByCategoryData[catKey] = svcs;
      }
    }

    const md = nunjucks.render("cloud-topology.md.njk", {
      data: topology, CATEGORY_PREFIX, servicesByCategory, servicesByCategoryData,
    });
    writeFileSync(OUTPUT_MD, md);
    console.log(`  Written: cloud-data-topology.md`);
  } else {
    console.warn(`  WARN: template not found at ${templatePath}`);
  }

  console.log("gen-topology: done.");
}

// --- Helpers --------------------------------------------------------------

function loadExistingVMMap(existing: any): Record<string, string> {
  if (!existing?.vms) return {};
  const map: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(existing.vms) as [string, any][]) {
    if (vm.ssh_alias) map[vm.ssh_alias] = vmId;
  }
  return map;
}

function resolveVmId(host: string, aliasMap: Record<string, string>, vms: Record<string, any>): string {
  if (host === "local" || host === "all") return host;
  if (aliasMap[host]) return aliasMap[host];
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias === host) return vmId;
  }
  return host;
}

function detectSSHKey(): string {
  const home = homedir();
  const candidates = [
    join(home, ".ssh", "id_rsa"),
    join(home, "git", "vault", "A0_keys", "ssh", "id_rsa"),
    "/home/diego/Mounts/Git/vault/A0_keys/ssh/id_rsa",
  ];
  return candidates.find((p) => existsSync(p)) || candidates[0];
}

main();
