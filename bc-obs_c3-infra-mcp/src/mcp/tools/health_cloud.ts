// ══════════════════════════════════════════════════════════════════════════════
// Cloud Health — 10-layer async multiplexed cloud diagnostic
//
// LAYERS:
//   1. SELF-CHECK        — C3 API mesh, C3 API public, WG interface, local docker, SSH agent
//   2. WIREGUARD MESH    — TCP :22 probe + ping fallback per VM
//   3. PLATFORM          — Docker version, disk%, memory%, load, uptime, container count
//   4. CONTAINERS        — All topology containers: Up/healthy/unhealthy/starting/exited
//   5. PUBLIC URLS       — curl each public HTTPS domain
//   6. PRIVATE URLS      — TCP probe each caddy upstream through mesh
//   7. CROSS-CHECKS      — public vs private reachability per caddy route
//   8. EXTERNAL          — Cloudflare DNS, GHCR, GHA failures, Resend API, GitHub API
//   9. DRIFT             — missing containers, unmanaged containers, caddy orphan routes
//  10. SECURITY          — TLS cert expiry, DMARC/SPF DNS, Authelia health, firewall ports
//
// Data sources: cloud-data-topology.json + cloud-data-caddy-routes.json
// Design: zero hardcoded service names. Promise.allSettled everywhere. SSH multiplexed.
// ══════════════════════════════════════════════════════════════════════════════

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/exec.js";
import { sshExecAsync } from "../../shared/ssh.js";
import { getVmSshAlias } from "../../shared/config.js";
import { getBearerToken } from "../../shared/http.js";
import { CLOUD_DATA_DIR, C3_API_MESH, C3_API_PUBLIC } from "../../shared/paths.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { performance } from "node:perf_hooks";

// ──────────────────────────────────────────────────────────────────────────────
// TYPES
// ──────────────────────────────────────────────────────────────────────────────

type Severity = "critical" | "warning" | "info";

interface Check {
  name: string;
  passed: boolean;
  details: string;
  durationMs: number;
  error?: string;
  severity?: Severity;
}

interface ContainerHealth {
  name: string;
  up: boolean;
  healthy: boolean | null; // null=no healthcheck, true=(healthy), false=(unhealthy)/(starting)
  status: string;
  image: string;
}

interface VmBatchData {
  dockerPs: string;
  dockerVersion: string;
  disk: string;
  memory: string;
  load: string;
  uptime: string;
  containers: ContainerHealth[];
}

interface TopologyVm {
  ip: string;
  wg_ip?: string | null;
  user?: string;
  ssh_alias?: string;
  description?: string;
  method?: string;
  [key: string]: unknown;
}

interface TopologyService {
  category: string;
  vm: string;
  containers?: string[];
  domain?: string;
  description?: string;
  frozen?: boolean;
  flake?: string;
  [key: string]: unknown;
}

interface CaddyRoute {
  domain: string;
  upstream: string;
  auth: string;
  type: "subdomain" | "path" | "mcp" | "github" | "special";
  basePath?: string;
}

interface DiagContext {
  vms: Record<string, TopologyVm>;
  services: Record<string, TopologyService>;
  vmBatch: Map<string, VmBatchData | null>;
  caddyRoutes: CaddyRoute[];
  bearerToken: string | null;
  reachableVms: Set<string>;
  sshOkVms: Set<string>;
  dockerOkVms: Set<string>;
}

// ──────────────────────────────────────────────────────────────────────────────
// UTILITIES
// ──────────────────────────────────────────────────────────────────────────────

const log = (msg: string) => process.stderr.write(`[cloud-health] ${msg}\n`);

function loadTopology(): { vms: Record<string, TopologyVm>; services: Record<string, TopologyService> } {
  const topoPath = join(CLOUD_DATA_DIR, "cloud-data-topology.json");
  if (!existsSync(topoPath)) {
    log("cloud-data-topology.json not found");
    return { vms: {}, services: {} };
  }
  try {
    const raw = JSON.parse(readFileSync(topoPath, "utf-8"));
    return { vms: raw.vms ?? {}, services: raw.services ?? {} };
  } catch (e) {
    log(`topology parse error: ${e}`);
    return { vms: {}, services: {} };
  }
}

function loadCaddyRoutes(): CaddyRoute[] {
  const filePath = join(CLOUD_DATA_DIR, "cloud-data-caddy-routes.json");
  if (!existsSync(filePath)) {
    log("caddy-routes.json not found");
    return [];
  }
  try {
    const data = JSON.parse(readFileSync(filePath, "utf-8"));
    const routes: CaddyRoute[] = [];

    for (const r of data.routes ?? []) {
      if (!r.domain) continue;
      routes.push({
        domain: r.domain,
        upstream: r.upstream ?? "",
        auth: r.auth ?? "two_factor",
        type: "subdomain",
      });
    }
    for (const group of data.path_routes ?? []) {
      for (const p of group.paths ?? []) {
        routes.push({
          domain: group.parent_domain,
          upstream: p.upstream ?? "",
          auth: p.auth ?? "two_factor",
          type: "path",
          basePath: p.base_path,
        });
      }
    }
    for (const group of data.mcp_routes ?? []) {
      for (const ep of group.endpoints ?? []) {
        routes.push({
          domain: group.parent_domain,
          upstream: ep.upstream ?? "",
          auth: "mcp",
          type: "mcp",
          basePath: ep.base_path,
        });
      }
    }
    for (const r of data.github_pages_proxies ?? []) {
      routes.push({
        domain: r.domain,
        upstream: "github-pages",
        auth: "none",
        type: "github",
      });
    }
    // Special routes
    if (data.special) {
      for (const s of Object.values(data.special) as Array<{ domain?: string }>) {
        if (s.domain) {
          routes.push({ domain: s.domain, upstream: "", auth: "special", type: "special" });
        }
      }
    }

    return routes;
  } catch (e) {
    log(`caddy-routes.json parse error: ${e}`);
    return [];
  }
}

async function timedCheck(
  name: string,
  fn: () => Promise<{ passed: boolean; details: string; severity?: Severity }>,
): Promise<Check> {
  const start = Date.now();
  try {
    const r = await fn();
    return { name, passed: r.passed, details: r.details, durationMs: Date.now() - start, severity: r.severity };
  } catch (err: unknown) {
    return {
      name,
      passed: false,
      details: "",
      error: err instanceof Error ? err.message : String(err),
      durationMs: Date.now() - start,
      severity: "critical",
    };
  }
}

/** Run a local command asynchronously */
function runLocal(cmd: string, args: string[], timeout = 8_000) {
  return execAsync(cmd, args, { timeout });
}

/** Run shell script locally */
function runShell(script: string, timeout = 8_000) {
  return execAsync("bash", ["-c", script], { timeout });
}

function getAlias(ctx: DiagContext, vmId: string): string {
  return ctx.vms[vmId]?.ssh_alias ?? vmId;
}

/** Get all active VMs (have wg_ip and ip is not TBD) */
function getActiveVms(ctx: DiagContext): [string, TopologyVm][] {
  return Object.entries(ctx.vms).filter(([_, v]) => v.wg_ip && v.ip !== "TBD");
}

/** Get all services deployed on remote VMs (not local, not frozen, not vm=all with no specific VM) */
function getRemoteServices(ctx: DiagContext): [string, TopologyService][] {
  return Object.entries(ctx.services).filter(
    ([_, s]) => s.vm && s.vm !== "local" && !s.frozen,
  );
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
  return dockerPs
    .split("\n")
    .filter((l) => l.trim() && l.includes("|"))
    .map((line) => {
      const parts = line.split("|");
      const name = (parts[0] || "").trim();
      const rawStatus = (parts[1] || "").trim();
      const image = (parts[2] || "").trim();
      const { up, healthy, status } = parseDockerHealth(rawStatus);
      return { name, up, healthy, status, image };
    });
}

/** Fuzzy container match: exact -> prefix -> substring */
function findContainer(containers: ContainerHealth[], name: string): ContainerHealth | null {
  return (
    containers.find((c) => c.name === name) ??
    containers.find((c) => c.name.startsWith(name)) ??
    containers.find((c) => c.name.includes(name)) ??
    null
  );
}

function containerCheckResult(c: ContainerHealth | null, _serviceName: string): { passed: boolean; details: string; severity?: Severity } {
  if (!c) return { passed: false, details: "NOT FOUND", severity: "warning" };
  const healthTag = c.healthy === true ? " (healthy)" : c.healthy === false ? " (UNHEALTHY)" : "";
  const passed = c.up && c.healthy !== false;
  const severity: Severity | undefined = !c.up ? "critical" : c.healthy === false ? "warning" : undefined;
  return { passed, details: `${c.name} ${c.status}${healthTag}`, severity };
}

// ──────────────────────────────────────────────────────────────────────────────
// OUTPUT FORMATTING
// ──────────────────────────────────────────────────────────────────────────────

function formatChecks(title: string, checks: Check[]): string {
  const passed = checks.filter((c) => c.passed).length;
  const total = checks.length;
  const crits = checks.filter((c) => !c.passed && c.severity === "critical").length;
  const warns = checks.filter((c) => !c.passed && c.severity === "warning").length;

  let statusTag = "ALL PASSED";
  if (passed < total) {
    const parts: string[] = [`${passed}/${total}`];
    if (crits > 0) parts.push(`${crits} CRIT`);
    if (warns > 0) parts.push(`${warns} WARN`);
    statusTag = parts.join(" ");
  }

  return [
    `${title}  [${statusTag}]`,
    "\u2500".repeat(70),
    ...checks.map((c) => {
      const icon = c.passed ? "\u2713" : "\u2717";
      const sev = c.severity && !c.passed ? ` [${c.severity.toUpperCase()}]` : "";
      const dur = c.durationMs > 0 ? ` ${c.durationMs}ms` : "";
      const err = c.error ? ` -- ${c.error}` : "";
      return `  ${icon} ${c.name.padEnd(36)}${dur.padStart(8)}  ${c.details}${sev}${err}`;
    }),
  ].join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// VM BATCH DATA COLLECTOR
// ──────────────────────────────────────────────────────────────────────────────

// CRITICAL: The batch script uses Go template syntax {{.Field}} for docker format strings.
// When passed through SSH via sshExecAsync (spawn("ssh", [..., target, command])),
// the command string is interpreted by the REMOTE bash shell.
//
// The fix: Assign the format string to a shell variable FIRST, then use $VAR.
// This prevents any shell from interpreting the curly braces.
const BATCH_SCRIPT = [
  // Define docker format strings as variables — prevents brace interpretation by any shell layer
  'FMT_VER="{{.ServerVersion}}"',
  'FMT_PS="{{.Names}}|{{.Status}}|{{.Image}}"',
  'echo "===dockerVersion==="',
  'timeout 3 docker info --format "$FMT_VER" 2>&1 | head -1',
  'echo "===disk==="',
  "df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,\"\"); print $5}' || echo N/A",
  'echo "===memory==="',
  "free -m 2>/dev/null | awk '/Mem:/{printf \"%d/%dMB (%.0f%%)\", $3, $2, $3/$2*100}' || echo N/A",
  "echo",
  'echo "===load==="',
  "cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo N/A",
  'echo "===uptime==="',
  "uptime -s 2>/dev/null || echo N/A",
  'echo "===dockerPs==="',
  'timeout 5 docker ps -a --format "$FMT_PS" 2>&1',
].join("\n");

function parseSection(output: string, name: string): string {
  const marker = `===${name}===`;
  const start = output.indexOf(marker);
  if (start === -1) return "";
  const afterMarker = start + marker.length;
  // Skip the newline after the marker
  const contentStart = output[afterMarker] === "\n" ? afterMarker + 1 : afterMarker;
  const end = output.indexOf("===", contentStart);
  return (end === -1 ? output.slice(contentStart) : output.slice(contentStart, end)).trim();
}

async function collectVmBatch(vmId: string): Promise<VmBatchData | null> {
  // Primary: full batch script
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
        uptime: parseSection(r.stdout, "uptime"),
        containers: parseContainers(dockerPs),
      };
    }
  } catch {
    /* fallback */
  }

  // Fallback: docker ps only — same variable trick for format string
  log(`batch failed for ${vmId}, trying docker ps fallback`);
  try {
    const cmd = 'FMT="{{.Names}}|{{.Status}}|{{.Image}}" && docker ps -a --format "$FMT" 2>&1';
    const r = await sshExecAsync(vmId, cmd, 10_000, true, 5);
    if (r.ok && r.stdout.trim()) {
      return {
        dockerPs: r.stdout.trim(),
        dockerVersion: "fallback",
        disk: "N/A",
        memory: "N/A",
        load: "N/A",
        uptime: "N/A",
        containers: parseContainers(r.stdout.trim()),
      };
    }
  } catch {
    /* fallback */
  }

  // Last resort: docker version only
  log(`docker ps failed for ${vmId}, trying docker info fallback`);
  try {
    const cmd = 'FMT="{{.ServerVersion}}" && docker info --format "$FMT" 2>&1 | head -1';
    const r = await sshExecAsync(vmId, cmd, 8_000, true, 5);
    if (r.ok) {
      return {
        dockerPs: "",
        dockerVersion: r.stdout.trim(),
        disk: "N/A",
        memory: "N/A",
        load: "N/A",
        uptime: "N/A",
        containers: [],
      };
    }
  } catch {
    /* give up */
  }

  return null;
}

async function collectAllVmBatches(vmIds: string[]): Promise<Map<string, VmBatchData | null>> {
  const results = await Promise.allSettled(
    vmIds.map(async (vmId) => ({ vmId, data: await collectVmBatch(vmId) })),
  );
  const map = new Map<string, VmBatchData | null>();
  for (const r of results) {
    if (r.status === "fulfilled") {
      map.set(r.value.vmId, r.value.data);
    } else {
      // Promise rejected — shouldn't happen with try/catch inside collectVmBatch, but be safe
      log(`collectVmBatch rejected: ${r.reason}`);
    }
  }
  return map;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 1: SELF-CHECK
// ──────────────────────────────────────────────────────────────────────────────

async function layer1SelfCheck(ctx: DiagContext): Promise<Check[]> {
  const checks = await Promise.allSettled([
    // 1a: C3 API via mesh
    timedCheck("C3 API mesh", async () => {
      const r = await runLocal("curl", ["-sf", "--max-time", "3", `${C3_API_MESH}/health`], 5_000);
      if (r.ok) return { passed: true, details: `${C3_API_MESH} OK`, severity: "critical" as Severity };
      return { passed: false, details: `${C3_API_MESH} unreachable`, severity: "critical" as Severity };
    }),

    // 1b: C3 API via public
    timedCheck("C3 API public", async () => {
      const r = await runLocal(
        "curl",
        ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", C3_API_PUBLIC + "/health"],
        8_000,
      );
      const code = r.stdout.trim();
      const ok = ["200", "401", "403"].includes(code);
      return { passed: ok, details: `${C3_API_PUBLIC} -> HTTP ${code}`, severity: "critical" as Severity };
    }),

    // 1c: WireGuard interface — probe the hub (gcp-proxy 10.0.0.1)
    timedCheck("WG interface", async () => {
      const r = await runShell("timeout 3 bash -c 'echo > /dev/tcp/10.0.0.1/22' 2>&1", 5_000);
      return { passed: r.ok, details: r.ok ? "10.0.0.1:22 OK" : "WG DOWN", severity: "critical" as Severity };
    }),

    // 1d: Local docker
    timedCheck("Local docker", async () => {
      const r = await runShell("docker info --format '{{.ServerVersion}}' 2>&1 | head -1", 5_000);
      if (r.ok && r.stdout.trim()) return { passed: true, details: `Docker ${r.stdout.trim()}`, severity: "info" as Severity };
      return { passed: false, details: "docker not available", severity: "info" as Severity };
    }),

    // 1e: SSH agent
    timedCheck("SSH agent", async () => {
      const r = await runShell("ssh-add -l 2>&1 | head -3", 3_000);
      const keys = r.stdout.trim().split("\n").filter((l) => l && !l.includes("no identities")).length;
      if (keys > 0) return { passed: true, details: `${keys} key(s) loaded`, severity: "info" as Severity };
      // Check if key file exists as fallback
      const keyCheck = await runShell("test -f ~/.ssh/id_rsa || test -f ~/.ssh/id_ed25519", 2_000);
      return {
        passed: keyCheck.ok,
        details: keyCheck.ok ? "key file present (no agent)" : "no keys found",
        severity: "info" as Severity,
      };
    }),
  ]);

  return checks.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "check threw", durationMs: 0, severity: "critical" as Severity },
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 2: WIREGUARD MESH
// ──────────────────────────────────────────────────────────────────────────────

async function layer2WgMesh(ctx: DiagContext): Promise<Check[]> {
  const vms = getActiveVms(ctx);

  const results = await Promise.allSettled(
    vms.map(([vmId, vm]) =>
      timedCheck(`${vm.ssh_alias ?? vmId} (${vm.wg_ip})`, async () => {
        // TCP probe port 22
        const tcp = await runShell(`timeout 3 bash -c 'echo > /dev/tcp/${vm.wg_ip}/22' 2>&1`, 5_000);
        if (tcp.ok) {
          ctx.reachableVms.add(vmId);
          return { passed: true, details: ":22 OK" };
        }
        // Fallback: ping
        const ping = await runLocal("ping", ["-c", "1", "-W", "2", vm.wg_ip!], 4_000);
        if (ping.ok) {
          ctx.reachableVms.add(vmId);
          return { passed: true, details: "ping OK (SSH port closed)", severity: "warning" as Severity };
        }
        return { passed: false, details: "unreachable", severity: "critical" as Severity };
      }),
    ),
  );

  return results.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "check threw", durationMs: 0, severity: "critical" as Severity },
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 3: PLATFORM
// ──────────────────────────────────────────────────────────────────────────────

async function layer3Platform(ctx: DiagContext): Promise<Check[]> {
  const reachableIds = Array.from(ctx.reachableVms);
  log(`Collecting batch data from ${reachableIds.length} VMs in parallel...`);

  ctx.vmBatch = await collectAllVmBatches(reachableIds);

  const checks: Check[] = [];
  for (const vmId of reachableIds) {
    const alias = getAlias(ctx, vmId);
    const data = ctx.vmBatch.get(vmId);

    if (!data) {
      checks.push({
        name: `${alias} platform`,
        passed: false,
        details: "SSH batch FAILED (all fallbacks exhausted)",
        durationMs: 0,
        severity: "critical",
      });
      continue;
    }

    ctx.sshOkVms.add(vmId);
    if (data.dockerVersion && data.dockerVersion !== "fallback") ctx.dockerOkVms.add(vmId);
    else if (data.containers.length > 0) ctx.dockerOkVms.add(vmId);

    const diskPct = parseInt(data.disk);
    const diskSev = !isNaN(diskPct) && diskPct >= 90 ? "critical" : !isNaN(diskPct) && diskPct >= 80 ? "warning" : undefined;
    const diskStr = !isNaN(diskPct) ? `${diskPct}%` : data.disk;
    const containerCount = data.containers.length;
    const unhealthyCount = data.containers.filter((c) => c.healthy === false).length;
    const exitedCount = data.containers.filter((c) => !c.up).length;

    const parts = [`Docker ${data.dockerVersion}`, `${containerCount} containers`];
    if (unhealthyCount > 0) parts.push(`${unhealthyCount} unhealthy`);
    if (exitedCount > 0) parts.push(`${exitedCount} exited`);
    parts.push(`disk:${diskStr}`, `mem:${data.memory}`, `load:${data.load}`);
    if (data.uptime !== "N/A") parts.push(`up:${data.uptime}`);

    const passed = data.dockerVersion.length > 0 && unhealthyCount === 0 && !diskSev;
    const sev: Severity | undefined = unhealthyCount > 0 ? "warning" : (diskSev as Severity | undefined);

    checks.push({ name: `${alias} platform`, passed, details: parts.join(" | "), durationMs: 0, severity: sev });
  }

  // Unreachable VMs
  for (const [vmId, vm] of getActiveVms(ctx)) {
    if (!ctx.reachableVms.has(vmId)) {
      checks.push({
        name: `${vm.ssh_alias ?? vmId} platform`,
        passed: false,
        details: "skipped (WG unreachable)",
        durationMs: 0,
        severity: "warning",
      });
    }
  }

  return checks;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 4: CONTAINERS
// ──────────────────────────────────────────────────────────────────────────────

async function layer4Containers(ctx: DiagContext): Promise<Check[]> {
  const checks: Check[] = [];

  for (const [svcName, svc] of Object.entries(ctx.services)) {
    if (!svc.vm || svc.vm === "local" || svc.frozen) continue;
    const containers = svc.containers ?? [];
    if (containers.length === 0) continue;

    // For vm=all services, check each active VM
    const targetVms = svc.vm === "all" ? Array.from(ctx.sshOkVms) : [svc.vm];

    for (const vmId of targetVms) {
      const vmData = ctx.vmBatch.get(vmId);
      if (!vmData) {
        // Only report if this is a specific VM (not "all")
        if (svc.vm !== "all") {
          checks.push({
            name: svcName,
            passed: false,
            details: `skipped (${getAlias(ctx, vmId)} offline)`,
            durationMs: 0,
            severity: "warning",
          });
        }
        continue;
      }

      for (const containerName of containers) {
        const c = findContainer(vmData.containers, containerName);
        const result = containerCheckResult(c, svcName);
        const label =
          containers.length > 1 || svc.vm === "all"
            ? `${svcName}/${containerName}${svc.vm === "all" ? `@${getAlias(ctx, vmId)}` : ""}`
            : svcName;
        checks.push({ name: label, ...result, durationMs: 0 });
      }
    }
  }

  return checks;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 5: PUBLIC URLS
// ──────────────────────────────────────────────────────────────────────────────

async function layer5PublicUrls(ctx: DiagContext): Promise<Check[]> {
  const bearer = ctx.bearerToken;
  const authArgs = bearer ? ["-H", `Authorization: Bearer ${bearer}`] : [];

  // Collect all domains from services
  const domainChecks: { name: string; domain: string }[] = [];
  for (const [name, svc] of Object.entries(ctx.services)) {
    if (svc.domain && svc.vm !== "local") {
      domainChecks.push({ name, domain: svc.domain });
    }
  }

  // Add caddy route domains not already covered
  const svcDomains = new Set(domainChecks.map((d) => d.domain));
  for (const route of ctx.caddyRoutes) {
    if (route.domain && !svcDomains.has(route.domain) && route.type !== "special") {
      domainChecks.push({ name: `route:${route.domain}`, domain: route.domain });
    }
  }

  const results = await Promise.allSettled(
    domainChecks.map(({ name, domain }) =>
      timedCheck(`${name}`, async () => {
        const url = domain.startsWith("http") ? domain : `https://${domain}`;
        const r = await runLocal(
          "curl",
          ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", ...authArgs, url],
          8_000,
        );
        const code = r.stdout.trim();
        // 200-399 = good, 401/403 = auth-protected (expected), 404 = route exists but path wrong
        const ok = /^[23]\d\d$/.test(code) || ["401", "403"].includes(code);
        return {
          passed: ok,
          details: `${domain} -> ${code}`,
          severity: ok ? undefined : ("warning" as Severity),
        };
      }),
    ),
  );

  return results.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "check threw", durationMs: 0, severity: "warning" as Severity },
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 6: PRIVATE URLS (TCP probe upstreams through mesh)
// ──────────────────────────────────────────────────────────────────────────────

async function layer6PrivateUrls(ctx: DiagContext): Promise<Check[]> {
  // Only check caddy routes that have real upstreams (host:port)
  const upstreamRoutes = ctx.caddyRoutes.filter(
    (r) => r.upstream && r.upstream.includes(":") && !r.upstream.includes("github"),
  );

  // Deduplicate by upstream
  const seen = new Set<string>();
  const uniqueRoutes = upstreamRoutes.filter((r) => {
    if (seen.has(r.upstream)) return false;
    seen.add(r.upstream);
    return true;
  });

  const results = await Promise.allSettled(
    uniqueRoutes.map((route) =>
      timedCheck(`${route.upstream}`, async () => {
        const [host, port] = route.upstream.split(":");
        // TCP probe through the WG mesh — these are docker network hostnames
        // resolved by the Caddy container, so we probe from gcp-proxy
        const r = await sshExecAsync(
          "gcp-proxy",
          `timeout 3 bash -c 'echo > /dev/tcp/${host}/${port}' 2>&1`,
          8_000,
          true,
          3,
        );
        if (r.ok) return { passed: true, details: `${route.upstream} OK` };
        // Try direct from the mesh if route points to a WG IP
        return { passed: false, details: `${route.upstream} unreachable from proxy`, severity: "warning" as Severity };
      }),
    ),
  );

  return results.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "probe threw", durationMs: 0, severity: "warning" as Severity },
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 7: CROSS-CHECKS (public vs private for each caddy route)
// ──────────────────────────────────────────────────────────────────────────────

async function layer7CrossChecks(ctx: DiagContext): Promise<Check[]> {
  const bearer = ctx.bearerToken;
  const authArgs = bearer ? ["-H", `Authorization: Bearer ${bearer}`] : [];

  const crossRoutes = ctx.caddyRoutes.filter(
    (r) => r.domain && r.upstream && r.upstream.includes(":") && !r.upstream.includes("github"),
  );

  const results = await Promise.allSettled(
    crossRoutes.map((route) =>
      timedCheck(`${route.domain}`, async () => {
        // Public side
        const url = route.domain.startsWith("http") ? route.domain : `https://${route.domain}`;
        const pub = await runLocal(
          "curl",
          ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", ...authArgs, url],
          8_000,
        );
        const pubCode = pub.stdout.trim();

        // Private side (upstream via proxy VM)
        const [host, port] = route.upstream.split(":");
        const priv = await sshExecAsync(
          "gcp-proxy",
          `timeout 3 bash -c 'echo > /dev/tcp/${host}/${port}' 2>&1`,
          8_000,
          true,
          3,
        );

        const pubOk = /^[23]\d\d$/.test(pubCode) || ["401", "403", "404"].includes(pubCode);
        const privOk = priv.ok;

        if (pubOk && privOk) return { passed: true, details: `pub:${pubCode} priv:OK` };
        if (!pubOk && privOk) return { passed: false, details: `pub:${pubCode} priv:OK -- Caddy/Authelia issue`, severity: "warning" as Severity };
        if (pubOk && !privOk) return { passed: false, details: `pub:${pubCode} priv:FAIL -- mesh routing issue`, severity: "warning" as Severity };
        return { passed: false, details: `pub:${pubCode} priv:FAIL -- service DOWN`, severity: "critical" as Severity };
      }),
    ),
  );

  return results.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "cross-check threw", durationMs: 0, severity: "warning" as Severity },
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 8: EXTERNAL
// ──────────────────────────────────────────────────────────────────────────────

async function layer8External(_ctx: DiagContext): Promise<Check[]> {
  const results = await Promise.allSettled([
    // 8a: Cloudflare DNS
    timedCheck("Cloudflare DNS", async () => {
      const r = await runShell("dig +short diegonmarcos.com @1.1.1.1 2>&1 | head -1", 5_000);
      const ip = r.stdout.trim();
      return { passed: ip.length > 0 && !ip.includes("error"), details: ip || "FAIL", severity: "critical" as Severity };
    }),

    // 8b: GHCR registry
    timedCheck("GHCR registry", async () => {
      const r = await runLocal("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://ghcr.io/v2/"], 8_000);
      const ok = ["200", "401"].includes(r.stdout.trim());
      return { passed: ok, details: `HTTP ${r.stdout.trim()}`, severity: "warning" as Severity };
    }),

    // 8c: GHA failures
    timedCheck("GHA workflows", async () => {
      const which = await runShell("command -v gh", 3_000);
      if (!which.ok) return { passed: true, details: "gh CLI not available (skipped)", severity: "info" as Severity };
      const r = await runLocal(
        "gh",
        [
          "run", "list",
          "--repo", "diegonmarcos/cloud",
          "--status", "failure",
          "--limit", "5",
          "--json", "name,updatedAt",
          "-q", '.[] | "\\(.name) (\\(.updatedAt[:16]))"',
        ],
        15_000,
      );
      if (!r.ok) return { passed: true, details: "gh query failed (skipped)", severity: "info" as Severity };
      const failures = r.stdout.trim().split("\n").filter((l) => l.trim());
      if (failures.length === 0) return { passed: true, details: "no recent failures" };
      return { passed: false, details: `${failures.length} failures: ${failures[0]}`, severity: "warning" as Severity };
    }),

    // 8d: Resend API (email delivery service)
    timedCheck("Resend API", async () => {
      const r = await runLocal("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://api.resend.com/health"], 8_000);
      const code = r.stdout.trim();
      const ok = code === "200";
      return { passed: ok, details: `HTTP ${code}`, severity: "info" as Severity };
    }),

    // 8e: GitHub API
    timedCheck("GitHub API", async () => {
      const r = await runLocal("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://api.github.com"], 8_000);
      const code = r.stdout.trim();
      const ok = ["200", "403"].includes(code); // 403 = rate limited but reachable
      return { passed: ok, details: `HTTP ${code}`, severity: "info" as Severity };
    }),
  ]);

  return results.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "check threw", durationMs: 0, severity: "info" as Severity },
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 9: DRIFT DETECTION
// ──────────────────────────────────────────────────────────────────────────────

async function layer9Drift(ctx: DiagContext): Promise<Check[]> {
  const checks: Check[] = [];

  // 9a: Missing containers (topology declares, Docker doesn't have)
  const missing: string[] = [];
  for (const [svcName, svc] of Object.entries(ctx.services)) {
    if (!svc.vm || svc.vm === "local" || svc.frozen) continue;
    const targetVms = svc.vm === "all" ? Array.from(ctx.sshOkVms) : [svc.vm];
    for (const vmId of targetVms) {
      const vmData = ctx.vmBatch.get(vmId);
      if (!vmData) continue;
      for (const cn of svc.containers ?? []) {
        if (!findContainer(vmData.containers, cn)) {
          missing.push(`${svcName}/${cn}@${getAlias(ctx, vmId)}`);
        }
      }
    }
  }
  checks.push({
    name: "Missing containers",
    passed: missing.length === 0,
    details:
      missing.length === 0
        ? "all declared containers found"
        : `${missing.length} missing: ${missing.slice(0, 8).join(", ")}${missing.length > 8 ? "..." : ""}`,
    durationMs: 0,
    severity: missing.length > 0 ? "warning" : undefined,
  });

  // 9b: Unmanaged containers (Docker has, topology doesn't declare)
  const declaredContainers = new Set<string>();
  for (const svc of Object.values(ctx.services)) {
    for (const cn of svc.containers ?? []) declaredContainers.add(cn);
  }
  const extra: string[] = [];
  for (const [vmId, data] of Array.from(ctx.vmBatch)) {
    if (!data) continue;
    for (const c of data.containers) {
      const matched = Array.from(declaredContainers).some(
        (d) => c.name === d || c.name.startsWith(d) || c.name.includes(d),
      );
      if (!matched) extra.push(`${getAlias(ctx, vmId)}/${c.name}`);
    }
  }
  checks.push({
    name: "Unmanaged containers",
    passed: extra.length <= 2, // allow a couple of system containers
    details:
      extra.length === 0
        ? "no unmanaged containers"
        : `${extra.length} unmanaged: ${extra.slice(0, 8).join(", ")}${extra.length > 8 ? "..." : ""}`,
    durationMs: 0,
    severity: extra.length > 2 ? "info" : undefined,
  });

  // 9c: Caddy route orphans (caddy has route, no service declares that domain)
  const configDomains = new Set<string>();
  for (const svc of Object.values(ctx.services)) {
    if (svc.domain) configDomains.add(svc.domain);
  }
  const orphanRoutes = ctx.caddyRoutes.filter(
    (r) => r.domain && r.type === "subdomain" && !configDomains.has(r.domain),
  );
  checks.push({
    name: "Caddy route orphans",
    passed: orphanRoutes.length <= 2,
    details:
      orphanRoutes.length === 0
        ? "all routes have matching services"
        : `${orphanRoutes.length} orphan: ${orphanRoutes
            .slice(0, 5)
            .map((r) => r.domain)
            .join(", ")}`,
    durationMs: 0,
    severity: orphanRoutes.length > 2 ? "info" : undefined,
  });

  return checks;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 10: SECURITY
// ──────────────────────────────────────────────────────────────────────────────

async function layer10Security(ctx: DiagContext): Promise<Check[]> {
  const keyDomains = ["diegonmarcos.com", "auth.diegonmarcos.com", "api.diegonmarcos.com", "mail.diegonmarcos.com"];

  const results = await Promise.allSettled([
    // 10a: TLS cert expiry on key domains
    ...keyDomains.map((domain) =>
      timedCheck(`TLS ${domain}`, async () => {
        const r = await runShell(
          `echo | openssl s_client -servername ${domain} -connect ${domain}:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//'`,
          8_000,
        );
        const dateStr = r.stdout.trim();
        if (!dateStr) return { passed: false, details: "cert check failed", severity: "warning" as Severity };
        const expiry = new Date(dateStr);
        const daysLeft = Math.floor((expiry.getTime() - Date.now()) / 86400000);
        if (daysLeft < 0) return { passed: false, details: `EXPIRED ${Math.abs(daysLeft)}d ago`, severity: "critical" as Severity };
        if (daysLeft < 7) return { passed: false, details: `expires in ${daysLeft}d`, severity: "critical" as Severity };
        if (daysLeft < 14) return { passed: true, details: `expires in ${daysLeft}d`, severity: "warning" as Severity };
        return { passed: true, details: `expires in ${daysLeft}d` };
      }),
    ),

    // 10b: DMARC record
    timedCheck("DMARC DNS", async () => {
      const r = await runShell("dig +short TXT _dmarc.diegonmarcos.com 2>&1 | head -1", 5_000);
      const txt = r.stdout.trim();
      const ok = txt.includes("v=DMARC1");
      return { passed: ok, details: ok ? "DMARC1 present" : `missing: ${txt || "no record"}`, severity: ok ? undefined : ("warning" as Severity) };
    }),

    // 10c: SPF record
    timedCheck("SPF DNS", async () => {
      const r = await runShell("dig +short TXT diegonmarcos.com 2>&1", 5_000);
      const ok = r.stdout.includes("v=spf1");
      return { passed: ok, details: ok ? "SPF present" : "missing", severity: ok ? undefined : ("warning" as Severity) };
    }),

    // 10d: Authelia health
    timedCheck("Authelia health", async () => {
      // Authelia runs on gcp-proxy — check via mesh
      const r = await runLocal(
        "curl",
        ["-sf", "--max-time", "3", "https://auth.diegonmarcos.com/api/health"],
        5_000,
      );
      if (r.ok) return { passed: true, details: "healthy" };
      // Fallback: check container directly
      const proxyData = ctx.vmBatch.get("gcp-E2-f_0");
      if (proxyData) {
        const c = findContainer(proxyData.containers, "authelia");
        if (c?.up && c.healthy !== false) return { passed: true, details: `container ${c.status}` };
      }
      return { passed: false, details: "unreachable", severity: "critical" as Severity };
    }),

    // 10e: Key firewall ports (check from outside — these should NOT be open)
    timedCheck("Firewall ports", async () => {
      // Check that dangerous ports are NOT reachable on the public proxy IP
      const proxyIp = ctx.vms["gcp-E2-f_0"]?.ip;
      if (!proxyIp) return { passed: true, details: "no proxy IP (skipped)", severity: "info" as Severity };
      const dangerousPorts = [22, 6379, 5432, 3306]; // SSH, Redis, Postgres, MySQL
      const openPorts: number[] = [];
      for (const port of dangerousPorts) {
        // Use short timeout — we expect these to fail (good)
        const r = await runShell(`timeout 2 bash -c 'echo > /dev/tcp/${proxyIp}/${port}' 2>&1`, 4_000);
        if (r.ok) openPorts.push(port);
      }
      // SSH (22) being open is expected for proxy
      const unexpected = openPorts.filter((p) => p !== 22);
      if (unexpected.length === 0) return { passed: true, details: "no unexpected ports open" };
      return { passed: false, details: `unexpected open: ${unexpected.join(", ")}`, severity: "critical" as Severity };
    }),
  ]);

  return results.map((r) =>
    r.status === "fulfilled"
      ? r.value
      : { name: "unknown", passed: false, details: "check threw", durationMs: 0, severity: "warning" as Severity },
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// ORCHESTRATION + TOOL REGISTRATION
// ══════════════════════════════════════════════════════════════════════════════

function buildContext(): DiagContext {
  const topo = loadTopology();
  return {
    vms: topo.vms,
    services: topo.services,
    vmBatch: new Map(),
    caddyRoutes: loadCaddyRoutes(),
    bearerToken: getBearerToken(),
    reachableVms: new Set(),
    sshOkVms: new Set(),
    dockerOkVms: new Set(),
  };
}

async function safeRun(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  try {
    return { content: [{ type: "text" as const, text: await fn() }] };
  } catch (err: unknown) {
    return {
      content: [{ type: "text" as const, text: `FATAL: ${err instanceof Error ? err.message : String(err)}` }],
    };
  }
}

type LayerFn = (ctx: DiagContext) => Promise<Check[]>;

async function runLayer(
  ctx: DiagContext,
  num: number,
  title: string,
  fn: LayerFn,
  marks: { layer: string; ms: number }[],
  t0: number,
): Promise<string> {
  const label = `${num}. ${title}`;
  log(`${label} starting...`);
  try {
    const checks = await fn(ctx);
    const ms = Math.round(performance.now() - t0);
    marks.push({ layer: label, ms });
    log(`${label}: done (${ms}ms, ${checks.filter((c) => c.passed).length}/${checks.length} pass)`);
    return formatChecks(label, checks);
  } catch (e) {
    const ms = Math.round(performance.now() - t0);
    marks.push({ layer: label, ms });
    log(`${label}: FAILED (${e})`);
    return `${label}  [FAILED]\n${"─".repeat(70)}\n  \u2717 ${e}`;
  }
}

export function registerHealthCloudTools(server: McpServer): void {
  // ── cloud-up: Quick infrastructure check (layers 1-3, ~10s) ─────────────
  server.tool(
    "cloud-up",
    "Quick infrastructure UP check: self-check + WG mesh + platform (~10s)",
    {},
    () =>
      safeRun(async () => {
        const ctx = buildContext();
        const t0 = performance.now();
        const marks: { layer: string; ms: number }[] = [];
        const sections: string[] = [];

        // Sequential: L1 -> L2 -> L3 (dependency chain)
        sections.push(await runLayer(ctx, 1, "SELF-CHECK", layer1SelfCheck, marks, t0));
        sections.push("", await runLayer(ctx, 2, "WIREGUARD MESH", layer2WgMesh, marks, t0));
        sections.push("", await runLayer(ctx, 3, "PLATFORM", layer3Platform, marks, t0));

        const totalMs = Math.round(performance.now() - t0);
        const allText = sections.join("\n");
        const pass = (allText.match(/\u2713/g) || []).length;
        const fail = (allText.match(/\u2717/g) || []).length;
        sections.push("", "\u2550".repeat(70), `RESULT: ${pass} passed, ${fail} failed (${(totalMs / 1000).toFixed(1)}s)`);
        return sections.join("\n");
      }),
  );

  // ── cloud-full: Comprehensive 10-layer diagnostic (~30-60s) ─────────────
  server.tool(
    "cloud-full",
    "Full 10-layer cloud diagnostic: self-check -> mesh -> platform -> containers -> URLs -> cross-checks -> external -> drift -> security (~60s)",
    {},
    () =>
      safeRun(async () => {
        const ctx = buildContext();
        const t0 = performance.now();
        const marks: { layer: string; ms: number }[] = [];
        const sections: string[] = [];

        // Sequential: L1 -> L2 -> L3 (each depends on previous)
        sections.push(await runLayer(ctx, 1, "SELF-CHECK", layer1SelfCheck, marks, t0));
        sections.push("", await runLayer(ctx, 2, "WIREGUARD MESH", layer2WgMesh, marks, t0));
        sections.push("", await runLayer(ctx, 3, "PLATFORM", layer3Platform, marks, t0));

        // Parallel: L4-L10 (all read cached vmBatch, no writes to ctx state)
        const parallelResults = await Promise.allSettled([
          runLayer(ctx, 4, "CONTAINERS", layer4Containers, marks, t0),
          runLayer(ctx, 5, "PUBLIC URLS", layer5PublicUrls, marks, t0),
          runLayer(ctx, 6, "PRIVATE URLS", layer6PrivateUrls, marks, t0),
          runLayer(ctx, 7, "CROSS-CHECKS", layer7CrossChecks, marks, t0),
          runLayer(ctx, 8, "EXTERNAL", layer8External, marks, t0),
          runLayer(ctx, 9, "DRIFT", layer9Drift, marks, t0),
          runLayer(ctx, 10, "SECURITY", layer10Security, marks, t0),
        ]);

        for (const r of parallelResults) {
          sections.push("", r.status === "fulfilled" ? r.value : `LAYER FAILED: ${r.reason}`);
        }

        // Performance summary
        const totalMs = Math.round(performance.now() - t0);
        const sortedMarks = [...marks].sort((a, b) => a.ms - b.ms);
        const perfLines = sortedMarks.map((m) => `  ${m.layer.padEnd(26)} ${(m.ms / 1000).toFixed(1)}s`);
        sections.push(
          "",
          [
            "PERFORMANCE",
            "\u2550".repeat(70),
            `  Wall-clock: ${(totalMs / 1000).toFixed(1)}s`,
            "",
            ...perfLines,
          ].join("\n"),
        );

        // Result summary
        const allText = sections.join("\n");
        const passCount = (allText.match(/\u2713/g) || []).length;
        const failCount = (allText.match(/\u2717/g) || []).length;
        sections.push("", "\u2550".repeat(70), `RESULT: ${passCount} passed, ${failCount} failed (${(totalMs / 1000).toFixed(1)}s)`);

        if (failCount === 0) {
          sections.push("ALL CHECKS PASSED -- Cloud is fully operational.");
        } else {
          // Dependency chain analysis
          const chain: string[] = [];
          const unreachable = getActiveVms(ctx).filter(([id]) => !ctx.reachableVms.has(id));
          if (unreachable.length > 0) {
            chain.push(`WG unreachable: ${unreachable.map(([_, v]) => v.ssh_alias ?? "?").join(", ")}`);
          }
          const proxyData = ctx.vmBatch.get("gcp-E2-f_0");
          if (proxyData) {
            const caddy = findContainer(proxyData.containers, "caddy");
            if (!caddy?.up) chain.push("Caddy DOWN -> all HTTPS routes affected");
            const authelia = findContainer(proxyData.containers, "authelia");
            if (!authelia?.up) chain.push("Authelia DOWN -> auth-protected services affected");
          } else if (ctx.reachableVms.has("gcp-E2-f_0")) {
            // VM reachable but no docker data
            chain.push("gcp-proxy: Docker unreachable -> proxy status unknown");
          } else {
            chain.push("gcp-proxy unreachable -> ALL public services affected");
          }
          if (chain.length > 0) {
            sections.push("", "DEPENDENCY CHAIN:");
            chain.forEach((c) => sections.push(`  -> ${c}`));
          }
        }

        log(`cloud-full complete: ${totalMs}ms, ${passCount} pass ${failCount} fail`);
        return sections.join("\n");
      }),
  );
}

// ── Standalone runner (GHA / CLI) ────────────────────────────────────────────
if (process.argv[1]?.endsWith("health_cloud.ts") || process.argv[1]?.endsWith("health_cloud.js")) {
  const mode = process.argv[2] === "quick" ? "cloud-up" : "cloud-full";
  (async () => {
    const { McpServer: S } = await import("@modelcontextprotocol/sdk/server/mcp.js");
    const server = new S({ name: "health-runner", version: "1.0.0" });
    registerHealthCloudTools(server);
    const tools = (server as any)._registeredTools;
    const tool = tools?.[mode];
    if (!tool?.handler) {
      console.error(`ERROR: ${mode} tool handler not found`);
      process.exit(1);
    }
    try {
      const result = await tool.handler({}, {});
      const text = result?.content?.[0]?.text ?? "No output";
      console.log(text);
      const failed = (text.match(/\u2717/g) || []).length;
      process.exit(failed > 0 ? 1 : 0);
    } catch (err) {
      console.error("FATAL:", err);
      process.exit(1);
    }
  })();
}
