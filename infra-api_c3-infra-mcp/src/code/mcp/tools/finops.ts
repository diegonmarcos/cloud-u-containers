// ── FinOps — Cloud financial operations (4 tools) ──
// VPS costs, service resource usage, infrastructure asset inventory

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/libs/exec.js";
import { sshExecAsync } from "../../shared/libs/ssh.js";
import { getVmSshAlias } from "../../shared/libs/config.js";
import { CLOUD_DATA_DIR, SOLUTIONS_DIR } from "../../shared/libs/paths.js";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";

// ──────────────────────────────────────────────────────────────────────────────
// TYPES & HELPERS
// ──────────────────────────────────────────────────────────────────────────────

interface TopologyVm {
  ip: string;
  wg_ip?: string;
  ssh_alias?: string;
  description?: string;
  [key: string]: unknown;
}

interface TopologyService {
  category: string;
  vm: string;
  containers?: string[];
  domain?: string;
  description?: string;
  frozen?: boolean;
  [key: string]: unknown;
}

interface VmCostProfile {
  alias: string;
  provider: string;
  tier: string;
  monthlyCost: number;
  specs: string;
  serviceCount: number;
  containerCount: number;
  diskUsage?: string;
  memUsage?: string;
  cpuLoad?: string;
}

interface ServiceCostEntry {
  name: string;
  vm: string;
  vmAlias: string;
  containers: number;
  category: string;
  hasDomain: boolean;
  frozen: boolean;
  port?: number;
}

const log = (msg: string) => process.stderr.write(`[finops] ${msg}\n`);

function loadTopology(): { vms: Record<string, TopologyVm>; services: Record<string, TopologyService> } {
  // Migrated 2026-04-27: read own build-c3-infra-mcp.json (has services map enriched
  // by deriveServiceConnections) + fall back to consolidated for full vm/service data.
  // 2026-04-27 migrated: cloud-data-topology.json legacy fallback dropped — consolidated covers all data
  const candidates = [
    "/app/build-c3-infra-mcp.json",
    join(CLOUD_DATA_DIR, "..", "cloud", "1_configs", "dist", "build-c3-infra-mcp.json"),
    "/app/_cloud-data-consolidated.json",
    join(CLOUD_DATA_DIR, "..", "cloud", "1_configs", "dist", "_cloud-data-consolidated.json"),
    join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json"),
  ];
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const raw = JSON.parse(readFileSync(p, "utf-8"));
      return { vms: raw.vms ?? {}, services: raw.services ?? {} };
    } catch { /* try next */ }
  }
  return { vms: {}, services: {} };
}

function loadServicePorts(): Map<string, number> {
  const ports = new Map<string, number>();
  try {
    const dirs = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
      .filter((d) => d.isDirectory()).map((d) => d.name);
    for (const dir of dirs) {
      const bjPath = join(SOLUTIONS_DIR, dir, "build.json");
      if (!existsSync(bjPath)) continue;
      try {
        const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
        if (bj.name && bj.ports?.app) ports.set(bj.name, Number(bj.ports.app));
      } catch { /* skip */ }
    }
  } catch { /* no solutions dir */ }
  return ports;
}

// ── VM cost model (known from cloud providers) ──
const VM_COSTS: Record<string, { provider: string; tier: string; monthly: number; specs: string }> = {
  "gcp-E2-f_0": { provider: "GCP", tier: "Free", monthly: 0, specs: "E2-micro (0.25 vCPU / 1GB)" },
  "oci-E2-f_0": { provider: "OCI", tier: "Free", monthly: 0, specs: "E2.1.Micro (1 OCPU / 1GB)" },
  "oci-E2-f_1": { provider: "OCI", tier: "Free", monthly: 0, specs: "E2.1.Micro (1 OCPU / 1GB)" },
  "oci-A1-f_0": { provider: "OCI", tier: "Free", monthly: 0, specs: "A1.Flex (4 OCPU / 24GB / 100GB)" },
  "gcp-T4-p_0": { provider: "GCP", tier: "Spot", monthly: 120, specs: "N1-Std-4 + T4 GPU (4 vCPU / 15GB)" },
  "oci-A1-p_0": { provider: "OCI", tier: "Paid", monthly: 30, specs: "A1.Flex Paid (8 OCPU / 32GB)" },
};

function formatTable(headers: string[], rows: string[][]): string {
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...rows.map((r) => (r[i] || "").length))
  );
  const sep = widths.map((w) => "─".repeat(w + 2)).join("┼");
  const fmtRow = (r: string[]) =>
    r.map((c, i) => ` ${(c || "").padEnd(widths[i])} `).join("│");
  return [fmtRow(headers), sep, ...rows.map(fmtRow)].join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// DATA COLLECTORS
// ──────────────────────────────────────────────────────────────────────────────

async function collectVmResources(vmId: string): Promise<{ disk?: string; mem?: string; load?: string }> {
  try {
    const script = [
      "echo '===disk==='",
      "df -h / 2>/dev/null | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}'",
      "echo '===mem==='",
      "free -m 2>/dev/null | awk '/Mem:/{printf \"%dMB/%dMB (%.0f%%)\", $3, $2, $3/$2*100}'",
      "echo",
      "echo '===load==='",
      "cat /proc/loadavg 2>/dev/null | awk '{print $1}'",
    ].join("\n");
    const r = await sshExecAsync(vmId, script, 10_000, true, 3);
    if (!r.ok) return {};
    const section = (name: string) => {
      const marker = `===${name}===`;
      const start = r.stdout.indexOf(marker);
      if (start === -1) return undefined;
      const after = start + marker.length;
      const contentStart = r.stdout[after] === "\n" ? after + 1 : after;
      const end = r.stdout.indexOf("===", contentStart);
      return (end === -1 ? r.stdout.slice(contentStart) : r.stdout.slice(contentStart, end)).trim() || undefined;
    };
    return { disk: section("disk"), mem: section("mem"), load: section("load") };
  } catch { return {}; }
}

async function countDockerContainers(vmId: string): Promise<{ running: number; total: number }> {
  try {
    const r = await sshExecAsync(vmId, "docker ps -a --format '{{.Status}}' 2>/dev/null | wc -l && docker ps --format '{{.Status}}' 2>/dev/null | wc -l", 8_000, true, 3);
    if (!r.ok) return { running: 0, total: 0 };
    const lines = r.stdout.trim().split("\n");
    return { total: parseInt(lines[0]) || 0, running: parseInt(lines[1]) || 0 };
  } catch { return { running: 0, total: 0 }; }
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: fin_ops_vps
// ──────────────────────────────────────────────────────────────────────────────

async function finOpsVps(): Promise<string> {
  const { vms, services } = loadTopology();
  const activeVms = Object.entries(vms).filter(([_, v]) => v.wg_ip && v.ip !== "TBD");
  const sections: string[] = [];

  // Count services per VM
  const vmServiceCount: Record<string, number> = {};
  const vmContainerCount: Record<string, number> = {};
  for (const [_, svc] of Object.entries(services)) {
    if (!svc.vm || svc.vm === "local" || svc.frozen) continue;
    vmServiceCount[svc.vm] = (vmServiceCount[svc.vm] || 0) + 1;
    vmContainerCount[svc.vm] = (vmContainerCount[svc.vm] || 0) + (svc.containers?.length || 0);
  }

  // Collect live resource data in parallel
  const resourceResults = await Promise.allSettled(
    activeVms.map(async ([vmId]) => ({
      vmId,
      resources: await collectVmResources(vmId),
      containers: await countDockerContainers(vmId),
    }))
  );
  const liveData = new Map<string, { resources: { disk?: string; mem?: string; load?: string }; containers: { running: number; total: number } }>();
  for (const r of resourceResults) {
    if (r.status === "fulfilled") liveData.set(r.value.vmId, r.value);
  }

  // Build table
  const rows: string[][] = [];
  let totalMonthly = 0;
  for (const [vmId, vm] of activeVms) {
    const cost = VM_COSTS[vmId] ?? { provider: "?", tier: "?", monthly: 0, specs: "unknown" };
    const alias = vm.ssh_alias ?? vmId;
    const live = liveData.get(vmId);
    totalMonthly += cost.monthly;

    rows.push([
      alias,
      cost.provider,
      cost.tier,
      cost.monthly === 0 ? "FREE" : `$${cost.monthly}/mo`,
      cost.specs,
      `${vmServiceCount[vmId] || 0} svc`,
      live ? `${live.containers.running}/${live.containers.total}` : "?",
      live?.resources.disk ?? "N/A",
      live?.resources.mem ?? "N/A",
      live?.resources.load ?? "N/A",
    ]);
  }

  sections.push("VPS COST ANALYSIS");
  sections.push("═".repeat(70));
  sections.push(formatTable(
    ["VM", "Cloud", "Tier", "Cost", "Specs", "Svc", "Containers", "Disk", "Memory", "Load"],
    rows,
  ));
  sections.push("");
  sections.push(`Total monthly: $${totalMonthly}/mo (${activeVms.filter(([id]) => (VM_COSTS[id]?.monthly ?? 0) === 0).length} free, ${activeVms.filter(([id]) => (VM_COSTS[id]?.monthly ?? 0) > 0).length} paid)`);

  // Cost per service
  const activeServices = Object.entries(services).filter(([_, s]) => s.vm !== "local" && !s.frozen).length;
  if (activeServices > 0 && totalMonthly > 0) {
    sections.push(`Cost per service: $${(totalMonthly / activeServices).toFixed(2)}/mo`);
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: fin_ops_services
// ──────────────────────────────────────────────────────────────────────────────

async function finOpsServices(): Promise<string> {
  const { vms, services } = loadTopology();
  const ports = loadServicePorts();
  const sections: string[] = [];

  const entries: ServiceCostEntry[] = [];
  for (const [name, svc] of Object.entries(services)) {
    if (svc.vm === "local") continue;
    const vmAlias = vms[svc.vm]?.ssh_alias ?? svc.vm;
    entries.push({
      name,
      vm: svc.vm,
      vmAlias,
      containers: svc.containers?.length ?? 0,
      category: svc.category,
      hasDomain: !!svc.domain,
      frozen: !!svc.frozen,
      port: ports.get(name),
    });
  }

  // Sort by VM then name
  entries.sort((a, b) => a.vmAlias.localeCompare(b.vmAlias) || a.name.localeCompare(b.name));

  sections.push("SERVICE RESOURCE MAP");
  sections.push("═".repeat(70));

  const rows = entries.map((e) => [
    e.name,
    e.vmAlias,
    e.category,
    String(e.containers),
    e.hasDomain ? "yes" : "no",
    e.port ? String(e.port) : "-",
    e.frozen ? "FROZEN" : "active",
  ]);

  sections.push(formatTable(
    ["Service", "VM", "Category", "Containers", "Domain", "Port", "Status"],
    rows,
  ));

  // Summary by VM
  sections.push("");
  sections.push("BY VM:");
  const byVm = new Map<string, { services: number; containers: number; domains: number }>();
  for (const e of entries) {
    const prev = byVm.get(e.vmAlias) ?? { services: 0, containers: 0, domains: 0 };
    prev.services++;
    prev.containers += e.containers;
    if (e.hasDomain) prev.domains++;
    byVm.set(e.vmAlias, prev);
  }
  for (const [alias, data] of byVm) {
    sections.push(`  ${alias}: ${data.services} services, ${data.containers} containers, ${data.domains} domains`);
  }

  // Summary by category
  sections.push("");
  sections.push("BY CATEGORY:");
  const byCat = new Map<string, number>();
  for (const e of entries) {
    byCat.set(e.category, (byCat.get(e.category) ?? 0) + 1);
  }
  for (const [cat, count] of [...byCat.entries()].sort((a, b) => b[1] - a[1])) {
    sections.push(`  ${cat}: ${count} services`);
  }

  sections.push("");
  sections.push(`Total: ${entries.length} services, ${entries.reduce((s, e) => s + e.containers, 0)} containers, ${entries.filter((e) => e.hasDomain).length} with domains, ${entries.filter((e) => e.frozen).length} frozen`);

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: fin_ops_assets
// ──────────────────────────────────────────────────────────────────────────────

async function finOpsAssets(): Promise<string> {
  const { vms, services } = loadTopology();
  const sections: string[] = [];

  sections.push("INFRASTRUCTURE ASSETS");
  sections.push("═".repeat(70));

  // 1. VMs
  sections.push("\n── VIRTUAL MACHINES ──");
  const vmRows = Object.entries(vms)
    .filter(([_, v]) => v.ip !== "TBD")
    .map(([id, v]) => [
      v.ssh_alias ?? id,
      v.ip ?? "-",
      v.wg_ip ?? "-",
      v.description ?? "-",
    ]);
  sections.push(formatTable(["VM", "Public IP", "WG IP", "Description"], vmRows));

  // 2. Domains
  sections.push("\n── DOMAINS ──");
  const domains = new Set<string>();
  for (const svc of Object.values(services)) {
    if (svc.domain) {
      const d = svc.domain.split("/")[0]; // strip path
      domains.add(d);
    }
  }
  const sortedDomains = [...domains].sort();
  sections.push(`  ${sortedDomains.length} unique domains:`);
  for (const d of sortedDomains) {
    sections.push(`    ${d}`);
  }

  // 3. Docker images (from topology containers)
  sections.push("\n── CONTAINER COUNT BY VM ──");
  const containersByVm = new Map<string, string[]>();
  for (const [name, svc] of Object.entries(services)) {
    if (!svc.vm || svc.vm === "local") continue;
    const alias = vms[svc.vm]?.ssh_alias ?? svc.vm;
    const prev = containersByVm.get(alias) ?? [];
    prev.push(...(svc.containers ?? []).map((c) => `${name}/${c}`));
    containersByVm.set(alias, prev);
  }
  for (const [alias, containers] of [...containersByVm.entries()].sort()) {
    sections.push(`  ${alias}: ${containers.length} declared containers`);
  }

  // 4. Ports in use
  sections.push("\n── PORTS ALLOCATED ──");
  const ports = loadServicePorts();
  const portsByVm = new Map<string, { name: string; port: number }[]>();
  for (const [name, svc] of Object.entries(services)) {
    const port = ports.get(name);
    if (!port || !svc.vm) continue;
    const alias = vms[svc.vm]?.ssh_alias ?? svc.vm;
    const prev = portsByVm.get(alias) ?? [];
    prev.push({ name, port });
    portsByVm.set(alias, prev);
  }
  for (const [alias, entries] of [...portsByVm.entries()].sort()) {
    const sorted = entries.sort((a, b) => a.port - b.port);
    sections.push(`  ${alias}: ${sorted.map((e) => `${e.port}(${e.name})`).join(", ")}`);
  }

  // 5. Cloudflare DNS records
  sections.push("\n── CLOUDFLARE DNS ──");
  // 2026-04-27 migrated: cloud-data-cloudflare-dns.json → _cloud-data-consolidated.json[.dns]
  const cfCandidates = [
    "/app/_cloud-data-consolidated.json",
    join(CLOUD_DATA_DIR, "..", "cloud", "1_configs", "dist", "_cloud-data-consolidated.json"),
    join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json"),
  ];
  const cfPath = cfCandidates.find((p) => existsSync(p));
  if (cfPath) {
    try {
      const cf = JSON.parse(readFileSync(cfPath, "utf-8"));
      // consolidated has .dns.derived_entries (records) + .dns.cloudflare (raw entries)
      const records = (Array.isArray(cf.dns?.cloudflare) && cf.dns.cloudflare.length > 0
        ? cf.dns.cloudflare
        : cf.dns?.derived_entries) ?? [];
      if (Array.isArray(records)) {
        sections.push(`  ${records.length} DNS records`);
        const byType = new Map<string, number>();
        for (const r of records) {
          const t = r.type ?? "?";
          byType.set(t, (byType.get(t) ?? 0) + 1);
        }
        for (const [t, c] of [...byType.entries()].sort()) {
          sections.push(`    ${t}: ${c}`);
        }
      }
    } catch { sections.push("  parse error"); }
  } else {
    sections.push("  _cloud-data-consolidated.json not found");
  }

  // 6. Git repos
  sections.push("\n── GIT REPOSITORIES ──");
  const repos = ["cloud", "cloud-data", "unix", "vault", "front", "tools"];
  for (const repo of repos) {
    const repoPath = join(CLOUD_DATA_DIR, "..", repo);
    if (existsSync(join(repoPath, ".git"))) {
      sections.push(`  ${repo}: ${repoPath}`);
    }
  }

  // Summary
  sections.push("");
  const totalContainers = [...containersByVm.values()].reduce((s, c) => s + c.length, 0);
  sections.push(`TOTALS: ${vmRows.length} VMs, ${sortedDomains.length} domains, ${totalContainers} containers, ${ports.size} ports allocated`);

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL REGISTRATION
// ──────────────────────────────────────────────────────────────────────────────

function safeRun(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  return fn()
    .then((text) => ({ content: [{ type: "text" as const, text }] }))
    .catch((err) => ({ content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }));
}

export function registerFinOpsTools(server: McpServer): void {
  server.tool(
    "obs.finops.all",
    "Full FinOps report: VPS costs + service map + asset inventory",
    {},
    () => safeRun(async () => {
      log("fin_ops: starting full report...");
      const [vps, services, assets] = await Promise.all([
        finOpsVps(),
        finOpsServices(),
        finOpsAssets(),
      ]);
      return [vps, "", services, "", assets].join("\n");
    }),
  );

  server.tool(
    "obs.finops.vps",
    "VPS cost analysis: provider, tier, monthly cost, resource usage per VM",
    {},
    () => safeRun(finOpsVps),
  );

  server.tool(
    "obs.finops.services",
    "Service resource map: services per VM, containers, categories, ports",
    {},
    () => safeRun(finOpsServices),
  );

  server.tool(
    "obs.finops.assets",
    "Infrastructure asset inventory: VMs, domains, containers, ports, DNS, repos",
    {},
    () => safeRun(finOpsAssets),
  );
}
