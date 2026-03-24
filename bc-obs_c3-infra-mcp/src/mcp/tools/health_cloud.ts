// ══════════════════════════════════════════════════════════════════════════════
// Cloud Full — Bulletproof async multiplexed 7-layer cloud diagnostic
//
// TIER 1: Data Collection (async, cached, parallel)
// TIER 2: Analysis Layers (consume cached data, cross-check, drift detect)
// TIER 3: Tool Registration + Output
//
// Design: zero hardcoded service names. Everything from config.json + cloud-data.
// Fallbacks on everything. Promise.allSettled everywhere. SSH multiplexed.
// ══════════════════════════════════════════════════════════════════════════════

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/exec.js";
import { sshExecAsync } from "../../shared/ssh.js";
import { getConfig, getVmSshAlias, getServicesForVm } from "../../shared/config.js";
import { getBearerToken } from "../../shared/http.js";
import { CLOUD_DATA_DIR, C3_API_MESH } from "../../shared/paths.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { performance } from "node:perf_hooks";

// ──────────────────────────────────────────────────────────────────────────────
// TYPES
// ──────────────────────────────────────────────────────────────────────────────

interface Check {
  name: string;
  passed: boolean;
  details: string;
  durationMs: number;
  error?: string;
  severity?: "critical" | "warning" | "info";
}

interface ContainerHealth {
  name: string;
  up: boolean;
  healthy: boolean | null; // null=no healthcheck, true=(healthy), false=(unhealthy)/(starting)
  status: string;
  restartCount: number;
  image: string;
}

interface VmBatchData {
  dockerPs: string;
  dockerVersion: string;
  disk: string;
  memory: string;
  load: string;
  containers: ContainerHealth[];
}

interface CaddyRoute {
  domain: string;
  upstream: string;
  auth: string;
  type: "subdomain" | "path" | "mcp" | "github" | "special";
  basePath?: string;
}

interface DiagContext {
  config: ReturnType<typeof getConfig>;
  vmBatch: Map<string, VmBatchData | null>;
  caddyRoutes: CaddyRoute[];
  bearerToken: string | null;
  reachableVms: Set<string>;
  sshOkVms: Set<string>;
  dockerOkVms: Set<string>;
  caddyOk: boolean;
  autheliaOk: boolean;
}

// ──────────────────────────────────────────────────────────────────────────────
// UTILITIES
// ──────────────────────────────────────────────────────────────────────────────

const log = (msg: string) => process.stderr.write(`[cloud-health] ${msg}\n`);

async function timedAsync(name: string, fn: () => Promise<{ passed: boolean; details: string; severity?: Check["severity"] }>): Promise<Check> {
  const start = Date.now();
  try {
    const r = await fn();
    return { name, passed: r.passed, details: r.details, durationMs: Date.now() - start, severity: r.severity };
  } catch (err: unknown) {
    return { name, passed: false, details: "", error: err instanceof Error ? err.message : String(err), durationMs: Date.now() - start, severity: "critical" };
  }
}

function runA(cmd: string, args: string[], timeout = 8_000) { return execAsync(cmd, args, { timeout }); }

function formatChecks(title: string, checks: Check[]): string {
  const passed = checks.filter(c => c.passed).length;
  const total = checks.length;
  const status = passed === total ? "ALL PASSED" : `${passed}/${total} PASSED`;
  return [
    `${title}  [${status}]`,
    "─".repeat(60),
    ...checks.map(c =>
      `  ${c.passed ? "✓" : "✗"} ${c.name.padEnd(32)} ${`${c.durationMs}ms`.padStart(8)}  ${c.details}${c.error ? ` — ${c.error}` : ""}`
    ),
  ].join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// CONTAINER HEALTH PARSING
// ──────────────────────────────────────────────────────────────────────────────

function parseDockerHealth(statusLine: string): { up: boolean; healthy: boolean | null; status: string } {
  const up = statusLine.startsWith("Up");
  let healthy: boolean | null = null;
  if (statusLine.includes("(healthy)")) healthy = true;
  else if (statusLine.includes("(unhealthy)")) healthy = false;
  else if (statusLine.includes("(health: starting)")) healthy = false;
  return { up, healthy, status: statusLine };
}

function parseContainers(dockerPs: string): ContainerHealth[] {
  return dockerPs.split("\n").filter(l => l.trim()).map(line => {
    const parts = line.split("|");
    const name = parts[0] || "";
    const rawStatus = parts[1] || "";
    const image = parts[2] || "";
    const restartCount = parseInt(parts[3] || "0") || 0;
    const { up, healthy, status } = parseDockerHealth(rawStatus);
    return { name, up, healthy, status, restartCount, image };
  });
}

function findContainer(containers: ContainerHealth[], name: string): ContainerHealth | null {
  // Exact → prefix → substring
  return containers.find(c => c.name === name)
    ?? containers.find(c => c.name.startsWith(name))
    ?? containers.find(c => c.name.includes(name))
    ?? null;
}

function containerCheckResult(c: ContainerHealth | null, serviceName: string): { passed: boolean; details: string } {
  if (!c) return { passed: false, details: "NOT FOUND" };
  const healthTag = c.healthy === true ? " (healthy)" : c.healthy === false ? " (UNHEALTHY)" : "";
  const restartWarn = c.restartCount > 3 ? ` ⚠️restart:${c.restartCount}` : "";
  const passed = c.up && c.healthy !== false;
  return { passed, details: `${c.name} ${c.status}${healthTag}${restartWarn}` };
}

// ──────────────────────────────────────────────────────────────────────────────
// TIER 1: CADDY ROUTE LOADER
// ──────────────────────────────────────────────────────────────────────────────

function loadCaddyRoutes(): CaddyRoute[] {
  const routes: CaddyRoute[] = [];
  const filePath = join(CLOUD_DATA_DIR, "cloud-data-caddy-routes.json");
  if (!existsSync(filePath)) {
    log("caddy-routes.json not found — cross-checks disabled");
    return routes;
  }
  try {
    const data = JSON.parse(readFileSync(filePath, "utf-8"));

    for (const r of (data.routes ?? [])) {
      routes.push({ domain: r.domain, upstream: r.upstream, auth: r.auth ?? "two_factor", type: "subdomain" });
    }
    for (const group of (data.path_routes ?? [])) {
      for (const p of (group.paths ?? [])) {
        routes.push({ domain: group.parent_domain, upstream: p.upstream, auth: p.auth ?? "two_factor", type: "path", basePath: p.base_path });
      }
    }
    for (const group of (data.mcp_routes ?? [])) {
      for (const ep of (group.endpoints ?? [])) {
        routes.push({ domain: group.parent_domain, upstream: ep.upstream, auth: "mcp", type: "mcp", basePath: ep.base_path });
      }
    }
    for (const r of (data.github_pages_proxies ?? [])) {
      routes.push({ domain: r.domain, upstream: "github-pages", auth: "none", type: "github" });
    }
  } catch (e) {
    log(`caddy-routes.json parse error: ${e}`);
  }
  return routes;
}

// ──────────────────────────────────────────────────────────────────────────────
// TIER 1: VM BATCH COLLECTOR (with fallback chain)
// ──────────────────────────────────────────────────────────────────────────────

const BATCH_SCRIPT = `
echo "===dockerVersion==="
timeout 3 docker info --format '{{.ServerVersion}}' 2>&1 | head -1
echo "===disk==="
df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}' || echo "N/A"
echo "===memory==="
free -m 2>/dev/null | awk '/Mem:/{printf "%d/%dMB (%.0f%%)", $3, $2, $3/$2*100}' || echo "N/A"
echo ""
echo "===load==="
cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A"
echo "===dockerPs==="
timeout 5 docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}|{{.RestartCount}}' 2>&1
`.trim();

function parseSection(output: string, name: string): string {
  const marker = `===${name}===`;
  const start = output.indexOf(marker);
  if (start === -1) return "";
  const afterMarker = start + marker.length + 1;
  const end = output.indexOf("===", afterMarker);
  return (end === -1 ? output.slice(afterMarker) : output.slice(afterMarker, end)).trim();
}

async function collectVmBatch(vmId: string): Promise<VmBatchData | null> {
  // Fallback 1: Full batch script
  try {
    const r = await sshExecAsync(vmId, BATCH_SCRIPT, 20_000, true, 5);
    if (r.ok && r.stdout.includes("===dockerPs===")) {
      const dockerPs = parseSection(r.stdout, "dockerPs");
      return {
        dockerPs,
        dockerVersion: parseSection(r.stdout, "dockerVersion"),
        disk: parseSection(r.stdout, "disk"),
        memory: parseSection(r.stdout, "memory"),
        load: parseSection(r.stdout, "load"),
        containers: parseContainers(dockerPs),
      };
    }
  } catch { /* fallback */ }

  // Fallback 2: Just docker ps
  log(`batch failed for ${vmId}, trying docker ps fallback`);
  try {
    const r = await sshExecAsync(vmId, "docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.RestartCount}}' 2>&1", 10_000, true, 5);
    if (r.ok && r.stdout.trim()) {
      return {
        dockerPs: r.stdout.trim(),
        dockerVersion: "fallback",
        disk: "N/A", memory: "N/A", load: "N/A",
        containers: parseContainers(r.stdout.trim()),
      };
    }
  } catch { /* fallback */ }

  // Fallback 3: Just docker info (VM reachable but docker broken?)
  log(`docker ps failed for ${vmId}, trying docker info fallback`);
  try {
    const r = await sshExecAsync(vmId, "docker info --format '{{.ServerVersion}}' 2>&1 | head -1", 8_000, true, 5);
    if (r.ok) {
      return {
        dockerPs: "", dockerVersion: r.stdout.trim(),
        disk: "N/A", memory: "N/A", load: "N/A", containers: [],
      };
    }
  } catch { /* give up */ }

  return null;
}

async function collectAllVmBatches(vmIds: string[]): Promise<Map<string, VmBatchData | null>> {
  const results = await Promise.allSettled(
    vmIds.map(async (vmId) => ({ vmId, data: await collectVmBatch(vmId) }))
  );
  const map = new Map<string, VmBatchData | null>();
  for (const r of results) {
    if (r.status === "fulfilled") map.set(r.value.vmId, r.value.data);
    else map.set("unknown", null);
  }
  return map;
}

// ──────────────────────────────────────────────────────────────────────────────
// TIER 1: GHA + OCI CHECKERS
// ──────────────────────────────────────────────────────────────────────────────

async function checkGhaFailures(): Promise<{ available: boolean; failures: string[] }> {
  try {
    const which = await runA("bash", ["-c", "command -v gh"], 3_000);
    if (!which.ok) return { available: false, failures: [] };
    const r = await runA("gh", ["run", "list", "--repo", "diegonmarcos/cloud", "--status", "failure", "--limit", "5", "--json", "name,updatedAt", "-q", '.[] | "\\(.name) (\\(.updatedAt[:16]))"'], 15_000);
    if (!r.ok) return { available: true, failures: [] };
    return { available: true, failures: r.stdout.trim().split("\n").filter(l => l.trim()) };
  } catch { return { available: false, failures: [] }; }
}

async function checkOciLifecycle(): Promise<{ available: boolean; states: Map<string, string> }> {
  const states = new Map<string, string>();
  try {
    const which = await runA("bash", ["-c", "command -v oci"], 3_000);
    if (!which.ok) return { available: false, states };
    // OCI CLI available — check VM lifecycle for OCI VMs
    const config = getConfig();
    const ociVms = Object.entries(config.vms).filter(([id]) => id.startsWith("oci-"));
    const results = await Promise.allSettled(ociVms.map(async ([vmId, vm]) => {
      const r = await runA("oci", ["compute", "instance", "list", "--lifecycle-state", "RUNNING", "--display-name", vm.ssh_alias ?? vmId, "--query", "data[0].\"lifecycle-state\"", "--raw-output"], 10_000);
      return { vmId, state: r.ok ? r.stdout.trim() || "UNKNOWN" : "QUERY_FAILED" };
    }));
    for (const r of results) {
      if (r.status === "fulfilled") states.set(r.value.vmId, r.value.state);
    }
    return { available: true, states };
  } catch { return { available: false, states }; }
}

// ══════════════════════════════════════════════════════════════════════════════
// TIER 2: ANALYSIS LAYERS
// ══════════════════════════════════════════════════════════════════════════════

// ── Layer 0: Self-Check ──────────────────────────────────────────────────────

async function layer0SelfCheck(ctx: DiagContext): Promise<Check[]> {
  return Promise.all([
    timedAsync("C3 API heartbeat", async () => {
      // Try mesh first, then localhost
      for (const url of [`${C3_API_MESH}/health`, "http://localhost:8081/health"]) {
        const r = await runA("curl", ["-sf", "--max-time", "3", url], 5_000);
        if (r.ok) return { passed: true, details: r.stdout.trim().slice(0, 50) || "ok", severity: "critical" as const };
      }
      return { passed: false, details: "UNREACHABLE (mesh + localhost)", severity: "critical" as const };
    }),
    timedAsync("WG interface", async () => {
      const r = await runA("bash", ["-c", "timeout 3 bash -c 'echo > /dev/tcp/10.0.0.6/22' 2>&1"], 5_000);
      return { passed: r.ok, details: r.ok ? "10.0.0.6:22 OK" : "WG DOWN", severity: "critical" as const };
    }),
  ]);
}

// ── Layer 1: WireGuard Mesh ──────────────────────────────────────────────────

async function layer1WgMesh(ctx: DiagContext): Promise<Check[]> {
  const vms = Object.entries(ctx.config.vms).filter(([_, v]) => v.wg_ip && v.ip !== "TBD");

  const checks = await Promise.allSettled(vms.map(([vmId, vm]) =>
    timedAsync(`${vm.ssh_alias ?? vmId} (${vm.wg_ip})`, async () => {
      // Fallback chain: TCP :22 → ping → unreachable
      const tcp = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${vm.wg_ip}/22' 2>&1`], 5_000);
      if (tcp.ok) {
        ctx.reachableVms.add(vmId);
        return { passed: true, details: ":22 OK" };
      }
      // Fallback: ping
      const ping = await runA("ping", ["-c", "1", "-W", "2", vm.wg_ip!], 4_000);
      if (ping.ok) {
        ctx.reachableVms.add(vmId);
        return { passed: true, details: "ping OK (SSH down)", severity: "warning" as const };
      }
      return { passed: false, details: "unreachable", severity: "warning" as const };
    })
  ));

  return checks.map(r => r.status === "fulfilled" ? r.value : { name: "unknown", passed: false, details: "check failed", durationMs: 0 });
}

// ── Layer 2: Platform ────────────────────────────────────────────────────────

async function layer2Platform(ctx: DiagContext): Promise<Check[]> {
  const reachableIds = [...ctx.reachableVms];
  log(`Collecting batch data from ${reachableIds.length} VMs in parallel...`);

  ctx.vmBatch = await collectAllVmBatches(reachableIds);

  const checks: Check[] = [];
  for (const vmId of reachableIds) {
    const vm = ctx.config.vms[vmId];
    const alias = vm?.ssh_alias ?? vmId;
    const data = ctx.vmBatch.get(vmId);

    if (!data) {
      checks.push({ name: `${alias} platform`, passed: false, details: "SSH batch FAILED (all fallbacks exhausted)", durationMs: 0, severity: "critical" });
      continue;
    }

    ctx.sshOkVms.add(vmId);
    if (data.dockerVersion && data.dockerVersion !== "fallback") ctx.dockerOkVms.add(vmId);
    else if (data.containers.length > 0) ctx.dockerOkVms.add(vmId); // fallback mode but has containers

    const diskPct = parseInt(data.disk);
    const diskWarn = !isNaN(diskPct) && diskPct >= 80 ? ` ⚠️disk:${diskPct}%` : ` disk:${data.disk}%`;
    const containerCount = data.containers.length;
    const unhealthyCount = data.containers.filter(c => c.healthy === false).length;
    const restartingCount = data.containers.filter(c => c.restartCount > 3).length;
    const warn = unhealthyCount > 0 ? ` ⚠️${unhealthyCount} unhealthy` : "";
    const rwarn = restartingCount > 0 ? ` ⚠️${restartingCount} crash-loop` : "";

    checks.push({
      name: `${alias} platform`,
      passed: data.dockerVersion.length > 0 && unhealthyCount === 0,
      details: `Docker ${data.dockerVersion} | ${containerCount} containers${warn}${rwarn}${diskWarn} | mem:${data.memory} | load:${data.load}`,
      durationMs: 0,
      severity: unhealthyCount > 0 ? "warning" : undefined,
    });
  }

  // Unreachable VMs
  for (const [vmId, vm] of Object.entries(ctx.config.vms)) {
    if (vm.wg_ip && vm.ip !== "TBD" && !ctx.reachableVms.has(vmId)) {
      checks.push({ name: `${vm.ssh_alias ?? vmId} platform`, passed: false, details: "skipped (unreachable)", durationMs: 0, severity: "warning" });
    }
  }

  return checks;
}

// ── Layer 3: Containers (ALL from config, dynamic) ───────────────────────────

async function layer3Containers(ctx: DiagContext): Promise<Check[]> {
  const checks: Check[] = [];

  for (const [svcName, svc] of Object.entries(ctx.config.services)) {
    const s = svc as any;
    if (!s.vm || s.vm === "local" || s.vm === "all") continue;
    if (s.frozen) continue;

    const containers: string[] = s.containers ?? [];
    if (containers.length === 0) continue;

    const vmData = ctx.vmBatch.get(s.vm);
    if (!vmData) {
      checks.push({ name: svcName, passed: false, details: `skipped (${getVmSshAlias(s.vm)} offline)`, durationMs: 0 });
      continue;
    }

    // Check each declared container
    for (const containerName of containers) {
      const c = findContainer(vmData.containers, containerName);
      const result = containerCheckResult(c, svcName);
      checks.push({ name: containers.length > 1 ? `${svcName}/${containerName}` : svcName, ...result, durationMs: 0 });
    }
  }

  return checks;
}

// ── Layer 4: Network (public + private + cross-checks) ───────────────────────

async function layer4Network(ctx: DiagContext): Promise<Check[]> {
  const checks: Check[] = [];
  const bearer = ctx.bearerToken;
  const authHeader = bearer ? ["-H", `Authorization: Bearer ${bearer}`] : [];

  // Build service→domain map from config
  const serviceDomains = new Map<string, string>();
  for (const [name, svc] of Object.entries(ctx.config.services)) {
    const s = svc as any;
    if (s.domain) serviceDomains.set(name, s.domain);
  }

  // Public URL checks — services with domains
  const publicChecks = [...serviceDomains.entries()].map(([name, domain]) =>
    timedAsync(`${name} public`, async () => {
      const url = domain.startsWith("http") ? domain : `https://${domain}`;
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", ...authHeader, url], 8_000);
      const code = r.stdout.trim();
      const ok = ["200", "301", "302", "303", "401", "403"].includes(code);
      return { passed: ok, details: `${domain} → ${code}`, severity: ok ? undefined : "warning" as const };
    })
  );

  // Caddy cross-checks: route upstream vs public domain
  const crossChecks = ctx.caddyRoutes
    .filter(r => r.type === "subdomain" && r.upstream && !r.upstream.includes("github"))
    .slice(0, 20) // limit to avoid flooding
    .map(route =>
      timedAsync(`${route.domain} cross`, async () => {
        // Public side
        const pub = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", ...authHeader, `https://${route.domain}`], 8_000);
        const pubCode = pub.stdout.trim();
        // Private side (upstream through mesh)
        const upstreamHost = route.upstream.split(":")[0];
        const upstreamPort = route.upstream.split(":")[1] || "80";
        const priv = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${upstreamHost}/${upstreamPort}' 2>&1`], 5_000);

        const pubOk = ["200", "301", "302", "303", "401", "403", "404"].includes(pubCode);
        const privOk = priv.ok;

        if (pubOk && privOk) return { passed: true, details: `pub:${pubCode} priv:OK` };
        if (!pubOk && privOk) return { passed: false, details: `pub:${pubCode} priv:OK — Caddy/Authelia issue`, severity: "warning" as const };
        if (pubOk && !privOk) return { passed: false, details: `pub:${pubCode} priv:FAIL — mesh routing issue`, severity: "warning" as const };
        return { passed: false, details: `pub:${pubCode} priv:FAIL — service DOWN`, severity: "critical" as const };
      })
    );

  const allResults = await Promise.allSettled([...publicChecks, ...crossChecks]);
  for (const r of allResults) {
    if (r.status === "fulfilled") checks.push(r.value);
  }

  return checks;
}

// ── Layer 5: External ────────────────────────────────────────────────────────

async function layer5External(ctx: DiagContext): Promise<Check[]> {
  const [dnsCheck, ghcrCheck, ghaResult, ociResult] = await Promise.allSettled([
    timedAsync("Cloudflare DNS", async () => {
      const r = await runA("bash", ["-c", "dig +short diegonmarcos.com @1.1.1.1 2>&1 | head -1"], 5_000);
      const ip = r.stdout.trim();
      return { passed: ip.length > 0 && !ip.includes("error"), details: ip || "FAIL" };
    }),
    timedAsync("GHCR registry", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://ghcr.io/v2/"], 8_000);
      const ok = ["200", "401"].includes(r.stdout.trim());
      return { passed: ok, details: `HTTP ${r.stdout.trim()}` };
    }),
    checkGhaFailures(),
    checkOciLifecycle(),
  ]);

  const checks: Check[] = [];

  if (dnsCheck.status === "fulfilled") checks.push(dnsCheck.value);
  if (ghcrCheck.status === "fulfilled") checks.push(ghcrCheck.value);

  // GHA failures
  const gha = ghaResult.status === "fulfilled" ? ghaResult.value : { available: false, failures: [] };
  if (!gha.available) {
    checks.push({ name: "GHA workflows", passed: true, details: "gh CLI not available (info)", durationMs: 0, severity: "info" });
  } else if (gha.failures.length === 0) {
    checks.push({ name: "GHA workflows", passed: true, details: "no recent failures", durationMs: 0 });
  } else {
    checks.push({ name: "GHA workflows", passed: false, details: `${gha.failures.length} recent failures: ${gha.failures[0]}`, durationMs: 0, severity: "warning" });
  }

  // OCI lifecycle
  const oci = ociResult.status === "fulfilled" ? ociResult.value : { available: false, states: new Map() };
  if (!oci.available) {
    checks.push({ name: "OCI lifecycle", passed: true, details: "oci CLI not available (info)", durationMs: 0, severity: "info" });
  } else {
    const stopped = [...oci.states.entries()].filter(([_, s]) => s !== "RUNNING");
    if (stopped.length === 0) {
      checks.push({ name: "OCI lifecycle", passed: true, details: `${oci.states.size} VMs RUNNING`, durationMs: 0 });
    } else {
      checks.push({ name: "OCI lifecycle", passed: false, details: `${stopped.map(([id, s]) => `${id}:${s}`).join(", ")}`, durationMs: 0, severity: "warning" });
    }
  }

  return checks;
}

// ── Layer 6: Drift Detection ─────────────────────────────────────────────────

async function layer6Drift(ctx: DiagContext): Promise<Check[]> {
  const checks: Check[] = [];

  // 6a: Missing containers (config declares, Docker doesn't have)
  const missing: string[] = [];
  for (const [svcName, svc] of Object.entries(ctx.config.services)) {
    const s = svc as any;
    if (!s.vm || s.vm === "local" || s.vm === "all" || s.frozen) continue;
    const vmData = ctx.vmBatch.get(s.vm);
    if (!vmData) continue;
    for (const cn of (s.containers ?? [])) {
      if (!findContainer(vmData.containers, cn)) missing.push(`${svcName}/${cn}`);
    }
  }
  checks.push({
    name: "Missing containers",
    passed: missing.length === 0,
    details: missing.length === 0 ? "all declared containers found" : `${missing.length} missing: ${missing.slice(0, 5).join(", ")}${missing.length > 5 ? "..." : ""}`,
    durationMs: 0,
    severity: missing.length > 0 ? "warning" : undefined,
  });

  // 6b: Extra containers (Docker has, no config declares)
  const declaredContainers = new Set<string>();
  for (const svc of Object.values(ctx.config.services)) {
    for (const cn of ((svc as any).containers ?? [])) declaredContainers.add(cn);
  }
  const extra: string[] = [];
  for (const [vmId, data] of ctx.vmBatch) {
    if (!data) continue;
    for (const c of data.containers) {
      // Fuzzy: check if any declared container matches this one
      const matched = [...declaredContainers].some(d => c.name === d || c.name.startsWith(d) || c.name.includes(d));
      if (!matched) extra.push(`${getVmSshAlias(vmId)}/${c.name}`);
    }
  }
  checks.push({
    name: "Unmanaged containers",
    passed: extra.length === 0,
    details: extra.length === 0 ? "no unmanaged containers" : `${extra.length} unmanaged: ${extra.slice(0, 5).join(", ")}${extra.length > 5 ? "..." : ""}`,
    durationMs: 0,
    severity: extra.length > 0 ? "info" : undefined,
  });

  // 6c: Caddy route orphans
  const configDomains = new Set<string>();
  for (const svc of Object.values(ctx.config.services)) {
    if ((svc as any).domain) configDomains.add((svc as any).domain);
  }
  const orphanRoutes = ctx.caddyRoutes.filter(r => r.type === "subdomain" && !configDomains.has(r.domain));
  checks.push({
    name: "Caddy route orphans",
    passed: orphanRoutes.length <= 2, // wildcard + root are expected
    details: orphanRoutes.length === 0 ? "all routes have matching services" : `${orphanRoutes.length} orphan routes: ${orphanRoutes.slice(0, 3).map(r => r.domain).join(", ")}`,
    durationMs: 0,
    severity: orphanRoutes.length > 2 ? "info" : undefined,
  });

  return checks;
}

// ══════════════════════════════════════════════════════════════════════════════
// TIER 3: ORCHESTRATION + TOOL REGISTRATION
// ══════════════════════════════════════════════════════════════════════════════

function buildContext(): DiagContext {
  return {
    config: getConfig(),
    vmBatch: new Map(),
    caddyRoutes: loadCaddyRoutes(),
    bearerToken: getBearerToken(),
    reachableVms: new Set(),
    sshOkVms: new Set(),
    dockerOkVms: new Set(),
    caddyOk: true,
    autheliaOk: true,
  };
}

async function safeToolAsync(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  try { return { content: [{ type: "text" as const, text: await fn() }] }; }
  catch (err: unknown) { return { content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }; }
}

export function registerHealthCloudTools(server: McpServer): void {

  // ── cloud-up: Quick infrastructure check (~10s) ──────────────────────────
  server.tool("cloud-up", "Quick infrastructure UP check: self-check + WG mesh + platform (~10s)", {},
    () => safeToolAsync(async () => {
      const ctx = buildContext();
      const t0 = performance.now();
      const sections: string[] = [];

      const l0 = await layer0SelfCheck(ctx);
      sections.push(formatChecks("0. SELF-CHECK", l0));

      const l1 = await layer1WgMesh(ctx);
      sections.push("", formatChecks("1. WIREGUARD MESH", l1));

      const l2 = await layer2Platform(ctx);
      sections.push("", formatChecks("2. PLATFORM", l2));

      const totalMs = Math.round(performance.now() - t0);
      const all = sections.join("\n");
      const pass = (all.match(/✓/g) || []).length;
      const fail = (all.match(/✗/g) || []).length;
      sections.push("", `${"═".repeat(60)}`, `RESULT: ${pass} passed, ${fail} failed (${(totalMs / 1000).toFixed(1)}s)`);
      return sections.join("\n");
    }),
  );

  // ── cloud-full: Comprehensive diagnostic (~30-45s) ───────────────────────
  server.tool("cloud-full", "Full 7-layer cloud diagnostic: infrastructure → containers → network → drift (~45s)", {},
    () => safeToolAsync(async () => {
      const ctx = buildContext();
      const marks: { layer: string; ms: number }[] = [];
      const t0 = performance.now();
      const mark = (layer: string) => { marks.push({ layer, ms: Math.round(performance.now() - t0) }); };
      const sections: string[] = [];

      const runLayer = async (name: string, fn: () => Promise<string>) => {
        log(`${name} starting...`);
        try {
          const result = await fn();
          mark(name);
          log(`${name}: done (${marks[marks.length - 1].ms}ms)`);
          sections.push("", result);
        } catch (e) {
          mark(name);
          log(`${name}: FAILED (${e})`);
          sections.push("", `${name}  [FAILED]\n${"─".repeat(60)}\n  ✗ ${e}`);
        }
      };

      mark("start");

      // Sequential: L0 → L1 → L2 (dependency chain)
      await runLayer("0. SELF-CHECK", async () => formatChecks("0. SELF-CHECK", await layer0SelfCheck(ctx)));
      await runLayer("1. WIREGUARD MESH", async () => {
        const checks = await layer1WgMesh(ctx);
        return formatChecks("1. WIREGUARD MESH", checks);
      });
      await runLayer("2. PLATFORM", async () => formatChecks("2. PLATFORM", await layer2Platform(ctx)));

      // Parallel: L3 + L4 + L5 + L6 (all read cached vmBatch)
      await Promise.all([
        runLayer("3. CONTAINERS", async () => formatChecks("3. CONTAINERS", await layer3Containers(ctx))),
        runLayer("4. NETWORK", async () => formatChecks("4. NETWORK", await layer4Network(ctx))),
        runLayer("5. EXTERNAL", async () => formatChecks("5. EXTERNAL", await layer5External(ctx))),
        runLayer("6. DRIFT", async () => formatChecks("6. DRIFT", await layer6Drift(ctx))),
      ]);

      // ── Performance ──
      const totalMs = Math.round(performance.now() - t0);
      const perfLines = marks.filter(m => m.layer !== "start").map(m => `  ${m.layer.padEnd(22)} ${(m.ms / 1000).toFixed(1)}s`);
      sections.push("", [`PERFORMANCE`, `${"═".repeat(60)}`, `  Wall-clock: ${(totalMs / 1000).toFixed(1)}s`, "", ...perfLines].join("\n"));

      // ── Result ──
      const allText = sections.join("\n");
      const passCount = (allText.match(/✓/g) || []).length;
      const failCount = (allText.match(/✗/g) || []).length;
      sections.push("", `${"═".repeat(60)}`, `RESULT: ${passCount} passed, ${failCount} failed (${(totalMs / 1000).toFixed(1)}s)`);

      if (failCount === 0) {
        sections.push("ALL CHECKS PASSED — Cloud is fully operational.");
      } else {
        const chain: string[] = [];
        const unreachable = Object.entries(ctx.config.vms).filter(([id, v]) => v.wg_ip && v.ip !== "TBD" && !ctx.reachableVms.has(id));
        if (unreachable.length > 0) chain.push(`WG unreachable: ${unreachable.map(([_, v]) => v.ssh_alias ?? "?").join(", ")}`);
        if (!ctx.caddyOk) chain.push("Caddy DOWN → HTTPS routes affected");
        if (!ctx.autheliaOk) chain.push("Authelia DOWN → auth-protected services affected");
        if (chain.length > 0) {
          sections.push("", `DEPENDENCY CHAIN:`);
          chain.forEach(c => sections.push(`  → ${c}`));
        }
      }

      log(`cloud_full complete: ${totalMs}ms, ${passCount}✓ ${failCount}✗`);
      return sections.join("\n");
    }),
  );
}

// ── Standalone runner (GHA / CLI) ────────────────────────────────────────────
if (process.argv[1]?.endsWith("health_cloud.ts")) {
  (async () => {
    const { McpServer: S } = await import("@modelcontextprotocol/sdk/server/mcp.js");
    const server = new S({ name: "health-runner", version: "1.0.0" });
    registerHealthCloudTools(server);
    const tools = (server as any)._registeredTools;
    const tool = tools?.["cloud-full"];
    if (!tool?.handler) {
      console.error("ERROR: cloud-full tool handler not found");
      process.exit(1);
    }
    try {
      const result = await tool.handler({}, {});
      const text = result?.content?.[0]?.text ?? "No output";
      console.log(text);
      const failed = (text.match(/✗/g) || []).length;
      process.exit(failed > 0 ? 1 : 0);
    } catch (err) {
      console.error("FATAL:", err);
      process.exit(1);
    }
  })();
}
