// gen-cloud-data.ts — Consolidated generator: ONE file → ONE output
//
// Replaces: gen-topology.ts, gen-configs.ts, gen-deps.ts, gen-home-manager.ts, gen-gha-config.ts
//
// Input sources (NO self-referential read, NO ~/.ssh/config):
//   1. config.json (repo root)                          → owner, vms overlay, native, vpss, deps
//   2. b_infra/vps_*/src/main.tf                        → terraform VM specs/IPs/firewall/storage
//   3. a_solutions/*/build.json                         → services + containers (scanBuildJsons)
//   4. a_solutions/*/dist/docker-compose.yml            → compose reconciliation (parseCompose)
//   5. a_solutions/*/src/package.json                   → npm deps per service
//   6. bb-sec_caddy/dist/Caddyfile                      → Caddy routes (parseCaddyfile)
//   7. bb-sec_authelia/dist/config/configuration.yml.tpl → Authelia ACL (parseAuthelia)
//   8. ba-clo_hickory-dns/dist/zones/                   → DNS zones (parseDNSZones)
//   9. vault/A0_keys/providers/wireguard/*/publickey    → WG public keys (source of truth)
//
// Output:
//   cloud-data/_cloud-data-consolidated.json
//
// Run: tsx gen-cloud-data.ts

import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "fs";
import { resolve, join } from "path";

import { scanBuildJsons, normalizeToContainers, CATEGORY_PREFIX, type BuildJsonEntry, type ContainerSpec } from "./parsers/build-json.js";
import { parseCompose } from "./parsers/compose.js";
import { parseCaddyfile } from "./parsers/caddyfile.js";
import { parseAuthelia } from "./parsers/authelia.js";
import { parseDNSZones } from "./parsers/dns.js";
import { parseWireGuard, parseOSFirewalls, parseOSFirewallGlobal } from "./parsers/wireguard.js";
import { parseTerraform } from "./parsers/terraform.js";
import { parseCloudflareRecords } from "./parsers/cloudflare.js";
import { parseNtfy } from "./parsers/ntfy.js";
import { parseMailu } from "./parsers/mailu.js";

// ═══════════════════════════════════════════════════════════════════════════
// Paths
// ═══════════════════════════════════════════════════════════════════════════

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT_DEFAULT = resolve(ENGINE_DIR, "../../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT_DEFAULT, "..");
const CLOUD_ROOT = process.env.GIT_BASE ? join(GIT_BASE, "cloud") : CLOUD_ROOT_DEFAULT;
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const INFRA_DIR = join(CLOUD_ROOT, "b_infra");
const CONFIG_JSON = join(CLOUD_ROOT, "config.json");

const CLOUD_DATA_DIR = join(CLOUD_ROOT, "cloud-data");
const OUTPUT_JSON = join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json");
const VAULT_WG_DIR = join(GIT_BASE, "vault", "A0_keys", "providers", "wireguard");

// ═══════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════

interface SystemDep {
  nix: string | null;
  apt: string | null;
  desc?: string;
  npm?: string;
}

interface ServiceDeps {
  service: string;
  folder: string;
  category: string;
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf-8"));
}

function takeHigher(existing: string | undefined, candidate: string): string {
  if (!existing) return candidate;
  return candidate > existing ? candidate : existing;
}

function sortObj(obj: Record<string, string>): Record<string, string> {
  return Object.fromEntries(Object.entries(obj).sort(([a], [b]) => a.localeCompare(b)));
}

/** Build alias → vmId map from config.json vms */
function buildAliasMap(configVms: Record<string, any>): Record<string, string> {
  const map: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(configVms)) {
    if (vm.ssh_alias) map[vm.ssh_alias] = vmId;
  }
  return map;
}

/** Resolve an ssh alias (or "local"/"all") to a VM ID */
function resolveVmId(host: string, aliasMap: Record<string, string>, vms: Record<string, any>): string {
  if (host === "local" || host === "all") return host;
  if (aliasMap[host]) return aliasMap[host];
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias === host) return vmId;
  }
  return host;
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

function main() {
  console.log("gen-cloud-data: scanning all sources...\n");

  // ── 1. Load config.json (overlay source) ───────────────────────────────
  if (!existsSync(CONFIG_JSON)) {
    console.error(`FATAL: config.json not found at ${CONFIG_JSON}`);
    process.exit(1);
  }
  const config = readJson(CONFIG_JSON) as any;
  const configVms: Record<string, any> = config.vms ?? {};
  const aliasMap = buildAliasMap(configVms);
  console.log(`  config.json: ${Object.keys(configVms).length} VMs, owner=${config.owner?.name}`);

  // ── 1b. Load WG public keys from vault (source of truth) ──────────────
  const vaultWgKeys: Record<string, string> = {};
  if (existsSync(VAULT_WG_DIR)) {
    for (const entry of readdirSync(VAULT_WG_DIR, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const pubFile = join(VAULT_WG_DIR, entry.name, "publickey");
      if (existsSync(pubFile)) {
        vaultWgKeys[entry.name] = readFileSync(pubFile, "utf8").trim();
      }
    }
    console.log(`  vault/wireguard: ${Object.keys(vaultWgKeys).length} public keys`);
  } else {
    console.log("  vault/wireguard: NOT FOUND — WG public keys will be null");
  }

  // ── 2. Parse Terraform for VM specs, storage, firewalls ────────────────
  const tfData = parseTerraform(INFRA_DIR);
  const totalFwRules = tfData.firewalls.reduce((sum, fw) => sum + fw.rules.length, 0);
  console.log(`  Terraform: ${Object.keys(tfData.vm_specs).length} VM specs, ${tfData.storage.length} storage, ${totalFwRules} firewall rules`);

  // Build terraform instance name → VM ID mapping
  // OCI: display_name matches VM ID directly (e.g. "oci-E2-f_0")
  // GCP: instance name (e.g. "arch-1") needs gcloud_instance mapping
  const tfNameToVmId: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(configVms)) {
    if (vm.gcloud_instance) tfNameToVmId[vm.gcloud_instance] = vmId;
  }

  // ── 3. Merge VMs: terraform specs + config.json overlay ────────────────
  const vms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(configVms)) {
    // Find matching terraform specs by display_name or gcloud_instance
    let tfSpecs = tfData.vm_specs[vmId]; // OCI: direct match
    if (!tfSpecs && vm.gcloud_instance) {
      tfSpecs = tfData.vm_specs[vm.gcloud_instance]; // GCP: via gcloud_instance
    }

    // Merge specs: config.json base, terraform overlay, machine_type lookup fallback
    const mergedSpecs = { ...(vm.specs ?? {}), ...(tfSpecs ?? {}) };
    // If cpu/ram still 0 (HCL parser can't handle for_each), resolve from machine_type lookup
    const machineType = mergedSpecs.machine_type || mergedSpecs.shape || "";
    if ((!mergedSpecs.cpu || mergedSpecs.cpu === 0 || !mergedSpecs.ram_gb || mergedSpecs.ram_gb === 0) && machineType) {
      const MACHINE_SPECS: Record<string, { cpu: number; ram_gb: number }> = {
        // GCP
        "e2-micro":       { cpu: 2, ram_gb: 1 },
        "e2-small":       { cpu: 2, ram_gb: 2 },
        "e2-medium":      { cpu: 2, ram_gb: 4 },
        "n1-standard-1":  { cpu: 1, ram_gb: 3.75 },
        "n1-standard-2":  { cpu: 2, ram_gb: 7.5 },
        "n1-standard-4":  { cpu: 4, ram_gb: 15 },
        "n1-standard-8":  { cpu: 8, ram_gb: 30 },
        // OCI
        "VM.Standard.E2.1.Micro": { cpu: 1, ram_gb: 1 },
        "VM.Standard.A1.Flex":    { cpu: 4, ram_gb: 24 },
      };
      const known = MACHINE_SPECS[machineType];
      if (known) {
        if (!mergedSpecs.cpu || mergedSpecs.cpu === 0) mergedSpecs.cpu = known.cpu;
        if (!mergedSpecs.ram_gb || mergedSpecs.ram_gb === 0) mergedSpecs.ram_gb = known.ram_gb;
      }
    }

    vms[vmId] = {
      // Terraform owns: ip (fallback to config), specs
      ip: vm.ip,
      specs: mergedSpecs,
      description: vm.description ?? "",
      // Config.json owns: wg, ssh, user, home, method, rescue, gha, public_ports
      wg_ip: vm.wg_ip,
      wg_public_key: vaultWgKeys[vm.ssh_alias] ?? null,  // vault is source of truth
      wg_port: vm.wg_port ?? 51820,
      wg_role: vm.wg_role ?? "spoke",
      user: vm.user,
      home: vm.home ?? (vm.user === "root" ? "/root" : `/home/${vm.user}`),
      method: vm.method ?? "key",
      ssh_alias: vm.ssh_alias,
      rescue_port: vm.rescue_port ?? 2200,
      public_ports: vm.public_ports ?? [],
      gha: vm.gha ?? null,
      // Optional provider/provisioning fields
      ...(vm.provider ? { provider: vm.provider } : {}),
      ...(vm.provisioning ? { provisioning: vm.provisioning } : {}),
      ...(vm.gcloud_instance ? { gcloud_instance: vm.gcloud_instance } : {}),
      ...(vm.gcloud_zone ? { gcloud_zone: vm.gcloud_zone } : {}),
      ...(vm.idle_shutdown ? { idle_shutdown: vm.idle_shutdown } : {}),
      ...(vm.notes ? { notes: vm.notes } : {}),
      // Derived (populated below)
      services: [] as string[],
      container_count: 0,
    };
  }

  // ── 4. Scan build.json → services ──────────────────────────────────────
  const buildEntries = scanBuildJsons(SOLUTIONS_DIR);
  console.log(`  build.json: ${buildEntries.length} services`);

  // ── 5. Build services map with compose reconciliation ──────────────────
  const services: Record<string, any> = {};

  for (const entry of buildEntries) {
    const compose = parseCompose(SOLUTIONS_DIR, entry.folder, entry.name);
    const vmId = resolveVmId(entry.vm, aliasMap, vms);

    // Normalize to containers (new schema or synthesized from flat)
    const containers = normalizeToContainers(entry);

    // Compute upstream from dns:port
    const computedUpstream = entry.dns && entry.port ? `${entry.dns}:${entry.port}` : undefined;

    // Derive container names from containers spec
    const containerNames = Object.values(containers).map(c => c.container_name);

    // Derive all ports from containers
    const allPorts: string[] = [];
    for (const c of Object.values(containers)) {
      if (c.port) allPorts.push(String(c.port));
    }
    // Merge compose ports
    for (const p of compose.ports) {
      if (!allPorts.includes(p)) allPorts.push(p);
    }

    // Derive all dns entries from containers
    const allDns: string[] = [];
    for (const c of Object.values(containers)) {
      if (c.dns) allDns.push(c.dns);
    }

    const svc: any = {
      category: entry.category,
      vm: vmId,
      folder: entry.folder,
      description: entry.description,
      // Domain + routing
      ...(entry.domain ? { domain: entry.domain } : {}),
      ...(entry.flake ? { flake: entry.flake } : {}),
      ...(entry.port != null ? { port: entry.port } : {}),
      ...(entry.dns ? { dns: entry.dns } : {}),
      ...(computedUpstream ? { upstream: computedUpstream } : {}),
      // Containers (new schema)
      containers,
      container_names: containerNames.length > 0 ? containerNames : compose.containers,
      all_ports: allPorts,
      all_dns: allDns,
      // Compose reconciliation
      compose: {
        containers: compose.containers,
        ports: compose.ports,
        networks: compose.networks,
      },
      // Declarative infrastructure fields (pass through from build.json)
      ...(entry.proxy ? { proxy: entry.proxy } : {}),
      ...(entry.ports ? { declared_ports: entry.ports } : {}),
      ...(entry.health ? { health: entry.health } : {}),
      ...(entry.monitoring ? { monitoring: entry.monitoring } : {}),
      ...(entry.backup ? { backup: entry.backup } : {}),
      ...(entry.notifications ? { notifications: entry.notifications } : {}),
      // Deploy overrides
      ...(entry.fallback_vm ? { fallback_vm: resolveVmId(entry.fallback_vm, aliasMap, vms) } : {}),
      // Extra service-specific fields
      ...(entry.extra ?? {}),
    };

    services[entry.name] = svc;
  }

  // ── 6. Aggregate services → VMs ───────────────────────────────────────
  for (const [svcName, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm) continue;
    vm.services.push(svcName);
    vm.container_count += (svc.container_names?.length ?? 0);
  }

  // ── 7. Firewalls (terraform + OS-level) ────────────────────────────────
  const osFirewalls = parseOSFirewalls(GIT_BASE);
  const osFirewallGlobal = parseOSFirewallGlobal(GIT_BASE);
  console.log(`  OS Firewalls: ${osFirewalls.length} VMs, docker_iptables=${osFirewallGlobal.docker_iptables}`);

  // Restructure firewalls into the consolidated shape
  const firewalls: any = {
    terraform: {} as Record<string, any>,
    os: {} as Record<string, any>,
    global: {
      docker_iptables: osFirewallGlobal.docker_iptables,
      forward_policy: osFirewallGlobal.forward_policy,
      docker_subnet: osFirewallGlobal.docker_subnet,
      wg_subnet: osFirewallGlobal.wg_subnet,
      forward_rules: osFirewallGlobal.forward_rules,
      nat_rules: osFirewallGlobal.nat_rules,
    },
  };

  // Group terraform firewalls by provider
  for (const fw of tfData.firewalls) {
    if (!firewalls.terraform[fw.provider]) {
      firewalls.terraform[fw.provider] = [];
    }
    firewalls.terraform[fw.provider].push({ scope: fw.scope, rules: fw.rules });
  }

  // OS firewalls: per-vm public_ports from config.json
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.public_ports?.length > 0) {
      firewalls.os[vm.ssh_alias || vmId] = vm.public_ports;
    }
  }

  // ── 8. Storage ─────────────────────────────────────────────────────────
  const storage = tfData.storage;

  // ── 9. DNS (internal zones + cloudflare) ───────────────────────────────
  const internalZones = parseDNSZones(SOLUTIONS_DIR);
  const cfRecords = parseCloudflareRecords(SOLUTIONS_DIR);
  console.log(`  DNS: ${internalZones.length} internal zones, ${cfRecords.length} Cloudflare records`);

  // Derive internal zone entries from service containers dns + vm wg_ip
  const derivedDnsEntries: Array<{ name: string; type: string; value: string; service: string }> = [];
  for (const [svcName, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip) continue;
    for (const dnsName of (svc.all_dns ?? [])) {
      if (dnsName) {
        derivedDnsEntries.push({
          name: dnsName,
          type: "A",
          value: vm.wg_ip,
          service: svcName,
        });
      }
    }
  }

  const dns = {
    internal_zones: internalZones,
    derived_entries: derivedDnsEntries,
    cloudflare: cfRecords,
  };

  // ── 10. Configs (Caddy, Authelia, ntfy, mailu) ─────────────────────────
  const caddyRoutes = parseCaddyfile(SOLUTIONS_DIR);
  const autheliaAcl = parseAuthelia(SOLUTIONS_DIR);
  const ntfyConfig = parseNtfy(SOLUTIONS_DIR);
  const mailuConfig = parseMailu(SOLUTIONS_DIR);
  console.log(`  Configs: ${caddyRoutes.length} Caddy routes, ${autheliaAcl.length} Authelia ACL rules`);

  const configs: any = {
    caddy: { routes: caddyRoutes },
    authelia: { acl: autheliaAcl },
  };
  if (ntfyConfig) configs.ntfy = ntfyConfig;
  if (mailuConfig) configs.mailu = mailuConfig;

  // ── 11. Deps (system + node per-service) ───────────────────────────────
  const { mergedDeps, mergedDevDeps, perServiceDeps } = scanNodeDeps(buildEntries);
  const systemDeps = readSystemDeps(config);
  console.log(`  Deps: ${perServiceDeps.length} services with package.json, ${Object.keys(mergedDeps).length + Object.keys(mergedDevDeps).length} merged packages`);

  const deps = {
    system: systemDeps.system,
    build: systemDeps.build,
    optional: systemDeps.optional,
    node: {
      required: config.deps?.node?.required ?? [],
      merged: {
        dependencies: sortObj(mergedDeps),
        devDependencies: sortObj(mergedDevDeps),
      },
      per_service: perServiceDeps.sort((a, b) => a.folder.localeCompare(b.folder)),
    },
    install: config.deps?.install ?? {},
    gha: config.deps?.gha ?? {},
  };

  // ── 12. VPSs ──────────────────────────────────────────────────────────
  const vpss: Record<string, any> = config.vpss ?? {};
  // Enrich with terraform provider info
  for (const prov of tfData.providers) {
    const existing = vpss[prov.name] ?? {};
    vpss[prov.name] = {
      ...existing,
      has_terraform: prov.has_terraform,
      folder: `b_infra/${prov.folder}`,
    };
  }

  // ── 13. WireGuard ─────────────────────────────────────────────────────
  const wgPeers = parseWireGuard(GIT_BASE);
  // Fallback: derive peers from VMs if parser found nothing
  if (wgPeers.length === 0) {
    for (const vm of Object.values(vms)) {
      if (vm.wg_ip) {
        wgPeers.push({
          name: vm.ssh_alias,
          wg_ip: vm.wg_ip,
          wg_public_key: vaultWgKeys[vm.ssh_alias] ?? null,
          endpoint: vm.ip ? `${vm.ip}:51820` : "dynamic",
          role: vm.wg_role || "spoke",
        });
      }
    }
  }
  // Enrich peers with wg_public_key from vault (source of truth)
  for (const peer of wgPeers) {
    peer.wg_public_key = vaultWgKeys[peer.name] ?? null;
  }

  // ── 14. Native section from config.json ────────────────────────────────
  const native = config.native ?? {};

  // ── 15. Home-manager data (previously gen-home-manager.ts) ─────────────
  const homeManagerVms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    if (!vm.ssh_alias) continue;
    homeManagerVms[vm.ssh_alias] = {
      vm_id: vmId,
      ip: vm.ip,
      wg_ip: vm.wg_ip,
      wg_public_key: vm.wg_public_key,
      wg_port: vm.wg_port,
      wg_role: vm.wg_role,
      user: vm.user,
      home: vm.home,
      rescue_port: vm.rescue_port,
      specs: vm.specs,
      public_ports: vm.public_ports,
      idle_shutdown: vm.idle_shutdown ?? null,
      containers: vm.services,
      method: vm.method,
      gha: vm.gha,
    };
  }

  const sshEntries = Object.entries(homeManagerVms).map(([alias, v]: [string, any]) => ({
    host: alias,
    hostname: v.wg_ip ?? v.ip,
    user: v.user,
    identity_file: v.method === "gcloud" ? "~/.ssh/google_compute_engine" : "~/.ssh/vault_id_rsa",
    port: 22,
  }));

  const wireguardSection = {
    subnet: native.wireguard?.subnet ?? "10.0.0.0/24",
    port: native.wireguard?.port ?? 51820,
    hub: native.wireguard?.wg_hub ?? null,
    peers: wgPeers,
    clients: Object.fromEntries(
      Object.entries(native.wireguard?.clients ?? {}).map(([name, client]: [string, any]) => [
        name,
        { ...client, wg_public_key: vaultWgKeys[name] ?? client.wg_public_key ?? null },
      ])
    ),
  };

  // ── 16. GHA config (previously gen-gha-config.ts) ──────────────────────
  const ghaVms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    if (!vm.ssh_alias || !vm.gha) continue;
    ghaVms[vm.ssh_alias] = {
      ssh_secret: vm.gha.ssh_secret,
      ...(vm.gha.host_literal ? { host: vm.ip, user: vm.user } : {}),
      ...(vm.gha.host_secret ? { host_secret: vm.gha.host_secret, user_secret: vm.gha.user_secret } : {}),
    };
  }

  const ghaServices: Record<string, any> = {};
  for (const [name, svc] of Object.entries(services) as [string, any][]) {
    const folder = svc.folder;
    if (!folder) continue;
    const bjPath = join(SOLUTIONS_DIR, folder, "build.json");
    if (!existsSync(bjPath)) continue;
    try {
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      const host = bj.deploy?.host;
      if (!host || host === "local" || host === "all") continue;
      if (bj.frozen) continue;
      ghaServices[name] = { dir: folder, vm: host, has_docker: !!bj.docker };
    } catch { continue; }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Assemble consolidated output
  // ═══════════════════════════════════════════════════════════════════════

  const consolidated = {
    _meta: {
      version: 2,
      generated_at: new Date().toISOString(),
      generated_by: "gen-cloud-data.ts",
    },
    owner: config.owner ?? {},
    home_manager: config.home_manager ?? { state_version: "24.11" },
    ssh_key: config.ssh_key ?? "/home/diego/git/vault/A0_keys/ssh/id_rsa",
    remote_base: config.remote_base ?? "/opt/containers",
    engine_folder: config.engine_folder ?? "bc-obs_c3-infra-mcp",
    vms,
    vpss,
    native: {
      wireguard: wireguardSection,
      dns: native.dns ?? { primary: "10.0.0.1", fallback: "1.1.1.1" },
      docker: native.docker ?? { subnet: "172.16.0.0/12", iptables: false },
      monitoring: native.monitoring ?? { ntfy_base: "https://rss.diegonmarcos.com" },
    },
    deps,
    services,
    firewalls,
    storage,
    dns,
    configs,
    // Embedded sub-outputs (previously separate generators)
    _home_manager: {
      vms: homeManagerVms,
      ssh_config: sshEntries,
    },
    _gha: {
      vms: ghaVms,
      services: ghaServices,
    },
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Write output
  // ═══════════════════════════════════════════════════════════════════════

  if (!existsSync(CLOUD_DATA_DIR)) {
    mkdirSync(CLOUD_DATA_DIR, { recursive: true });
  }

  writeFileSync(OUTPUT_JSON, JSON.stringify(consolidated, null, 2) + "\n");

  const svcCount = Object.keys(services).length;
  const vmCount = Object.keys(vms).length;
  const depCount = perServiceDeps.length;
  console.log(`\ngen-cloud-data: written _cloud-data-consolidated.json`);
  console.log(`  ${vmCount} VMs, ${svcCount} services, ${depCount} service deps, ${caddyRoutes.length} Caddy routes`);
  console.log("gen-cloud-data: done.");
}

// ═══════════════════════════════════════════════════════════════════════════
// Deps scanning (from gen-deps.ts)
// ═══════════════════════════════════════════════════════════════════════════

function scanNodeDeps(buildEntries: BuildJsonEntry[]): {
  mergedDeps: Record<string, string>;
  mergedDevDeps: Record<string, string>;
  perServiceDeps: ServiceDeps[];
} {
  const mergedDeps: Record<string, string> = {};
  const mergedDevDeps: Record<string, string> = {};
  const perServiceDeps: ServiceDeps[] = [];

  const folders = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  for (const folder of folders) {
    const pkgPath = join(SOLUTIONS_DIR, folder, "src", "package.json");
    if (!existsSync(pkgPath)) continue;

    // Find matching build entry for metadata
    const buildJsonPath = join(SOLUTIONS_DIR, folder, "build.json");
    let category = "unknown";
    let serviceName = folder;
    if (existsSync(buildJsonPath)) {
      try {
        const bj = readJson(buildJsonPath) as { name?: string; category?: string };
        serviceName = bj.name ?? folder;
        category = bj.category ?? "unknown";
      } catch { /* use defaults */ }
    }

    try {
      const pkg = readJson(pkgPath) as {
        dependencies?: Record<string, string>;
        devDependencies?: Record<string, string>;
      };
      const deps = pkg.dependencies ?? {};
      const devDeps = pkg.devDependencies ?? {};

      for (const [k, v] of Object.entries(deps)) {
        mergedDeps[k] = takeHigher(mergedDeps[k], v);
      }
      for (const [k, v] of Object.entries(devDeps)) {
        mergedDevDeps[k] = takeHigher(mergedDevDeps[k], v);
      }

      perServiceDeps.push({
        service: serviceName,
        folder,
        category,
        dependencies: deps,
        devDependencies: devDeps,
      });
    } catch (e) {
      console.warn(`  WARN: failed to parse ${pkgPath}: ${e}`);
    }
  }

  // Include repo-level config.json deps.node.required
  if (existsSync(CONFIG_JSON)) {
    try {
      const config = readJson(CONFIG_JSON) as { deps?: { node?: { required?: string[] } } };
      const required = config.deps?.node?.required ?? [];
      for (const pkg of required) {
        if (!mergedDeps[pkg] && !mergedDevDeps[pkg]) {
          mergedDeps[pkg] = "latest";
        }
      }
    } catch { /* skip */ }
  }

  return { mergedDeps, mergedDevDeps, perServiceDeps };
}

function readSystemDeps(config: any): {
  system: Record<string, SystemDep>;
  build: Record<string, SystemDep>;
  optional: Record<string, SystemDep>;
} {
  return {
    system: config.deps?.system ?? {},
    build: config.deps?.build ?? {},
    optional: config.deps?.optional ?? {},
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Run
// ═══════════════════════════════════════════════════════════════════════════

main();
