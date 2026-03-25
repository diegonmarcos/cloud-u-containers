// ══════════════════════════════════════════════════════════════════════════════
// Cloud Health — 10-layer async multiplexed cloud diagnostic
//
// LAYERS:
//   1. SELF-CHECK        — C3 API mesh, C3 API public, WG interface, local docker, SSH agent
//   2. WIREGUARD MESH    — TCP :22 probe + ping fallback per VM
//   3. PLATFORM          — Docker version, disk%, memory%, load, uptime, container count
//   4. CONTAINERS        — All topology containers: Up/healthy/unhealthy/starting/exited
//   5. PUBLIC URLS       — curl each public HTTPS domain
//   6. PRIVATE URLS      — curl each service via WG mesh (wg_ip:port)
//   7. CROSS-CHECKS      — public URL vs container health per service
//   8. EXTERNAL          — Cloudflare DNS, GHCR, GHA failures, Resend API, GitHub API
//   9. DRIFT             — missing containers, unmanaged containers, caddy orphan routes
//  10. SECURITY          — TLS cert expiry, DMARC/SPF DNS, Authelia health, firewall ports
//
// Data sources: cloud-data-topology.json + cloud-data-caddy-routes.json + build.json (ports)
// Design: zero hardcoded service names. Promise.allSettled everywhere. SSH multiplexed.
// ══════════════════════════════════════════════════════════════════════════════

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/exec.js";
import { sshExecAsync } from "../../shared/ssh.js";
import { getVmSshAlias } from "../../shared/config.js";
import { getBearerToken } from "../../shared/http.js";
import { CLOUD_DATA_DIR, C3_API_MESH, C3_API_PUBLIC, SOLUTIONS_DIR } from "../../shared/paths.js";
import { readFileSync, existsSync, readdirSync } from "fs";
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
  servicePorts: Map<string, number>; // service name → app port
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

/** Discover service ports from build.json files on disk */
function loadServicePorts(): Map<string, number> {
  const ports = new Map<string, number>();
  try {
    const dirs = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
    for (const dir of dirs) {
      const bjPath = join(SOLUTIONS_DIR, dir, "build.json");
      if (!existsSync(bjPath)) continue;
      try {
        const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
        if (bj.name && bj.ports?.app) {
          ports.set(bj.name, Number(bj.ports.app));
        }
      } catch { /* skip */ }
    }
  } catch { /* no solutions dir */ }
  return ports;
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
  return ctx.vms[vmId]?.ssh_alias ?? getVmSshAlias(vmId);
}

/** Get all active VMs (have wg_ip and ip is not TBD) */
function getActiveVms(ctx: DiagContext): [string, TopologyVm][] {
  return Object.entries(ctx.vms).filter(([_, v]) => v.wg_ip && v.ip !== "TBD");
}

/** Get all services deployed on remote VMs (not local, not frozen) */
function getRemoteServices(ctx: DiagContext): [string, TopologyService][] {
  return Object.entries(ctx.services).filter(
    ([_, s]) => s.vm && s.vm !== "local" && !s.frozen,
  );
}

/** Get WG IP for a VM */
function vmWgIp(ctx: DiagContext, vmId: string): string | null {
  return ctx.vms[vmId]?.wg_ip ?? null;
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

// SSH batch script — collects all platform data in one SSH round-trip.
// Docker format strings use Go template {{.Field}} syntax.
// We assign them to shell variables to prevent any bash interpretation.
const BATCH_SCRIPT = [
  'FMT_VER=\'{{.ServerVersion}}\'',
  'FMT_PS=\'{{.Names}}|{{.Status}}|{{.Image}}\'',
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
  'timeout 10 docker ps -a --format "$FMT_PS" 2>&1',
].join("\n");

function parseSection(output: string, name: string): string {
  const marker = `===${name}===`;
  const start = output.indexOf(marker);
  if (start === -1) return "";
  const afterMarker = start + marker.length;
  const contentStart = output[afterMarker] === "\n" ? afterMarker + 1 : afterMarker;
  const end = output.indexOf("===", contentStart);
  return (end === -1 ? output.slice(contentStart) : output.slice(contentStart, end)).trim();
}

/** Validate docker version string — reject error messages */
function isValidDockerVersion(v: string): boolean {
  if (!v || v.length > 20) return false;
  // Valid version looks like "27.5.1" or "24.0.7"
  if (/^\d+\.\d+/.test(v)) return true;
  return false;
}

async function collectVmBatch(vmId: string): Promise<VmBatchData | null> {
  // Primary: full batch script
  try {
    const r = await sshExecAsync(vmId, BATCH_SCRIPT, 20_000, true, 5);
    if (r.ok || r.stdout.includes("===dockerPs===")) {
      const dockerPs = parseSection(r.stdout, "dockerPs");
      const dockerVersion = parseSection(r.stdout, "dockerVersion");
      // Filter out error messages from docker version
      const validVersion = isValidDockerVersion(dockerVersion) ? dockerVersion : "";
      const containers = parseContainers(dockerPs);
      return {
        dockerPs,
        dockerVersion: validVersion || (containers.length > 0 ? "detected" : ""),
        disk: parseSection(r.stdout, "disk"),
        memory: parseSection(r.stdout, "memory"),
        load: parseSection(r.stdout, "load"),
        uptime: parseSection(r.stdout, "uptime"),
        containers,
      };
    }
  } catch { /* fallback */ }

  // Fallback 1: docker ps only (simpler command, more likely to work)
  log(`batch failed for ${vmId}, trying docker ps fallback`);
  try {
    const r = await sshExecAsync(
      vmId,
      "docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>&1",
      10_000, true, 5,
    );
    if (r.ok && r.stdout.trim() && r.stdout.includes("|")) {
      return {
        dockerPs: r.stdout.trim(),
        dockerVersion: "fallback",
        disk: "N/A", memory: "N/A", load: "N/A", uptime: "N/A",
        containers: parseContainers(r.stdout.trim()),
      };
    }
  } catch { /* fallback */ }

  // Fallback 2: docker ps with single-quote escaping
  log(`docker ps failed for ${vmId}, trying quoted format`);
  try {
    const cmd = `FMT='{{.Names}}|{{.Status}}|{{.Image}}' && docker ps -a --format "$FMT" 2>&1`;
    const r = await sshExecAsync(vmId, cmd, 10_000, true, 5);
    if (r.ok && r.stdout.trim() && r.stdout.includes("|")) {
      return {
        dockerPs: r.stdout.trim(),
        dockerVersion: "fallback",
        disk: "N/A", memory: "N/A", load: "N/A", uptime: "N/A",
        containers: parseContainers(r.stdout.trim()),
      };
    }
  } catch { /* fallback */ }

  // Fallback 3: docker ps with table format and parse columns
  log(`quoted format failed for ${vmId}, trying table parse`);
  try {
    const r = await sshExecAsync(vmId, "docker ps -a 2>&1", 10_000, true, 5);
    if (r.ok && r.stdout.includes("CONTAINER ID")) {
      // Parse table output — less structured but works
      const lines = r.stdout.split("\n").slice(1).filter((l) => l.trim());
      const containers: ContainerHealth[] = lines.map((line) => {
        // Docker ps table: CONTAINER ID  IMAGE  COMMAND  CREATED  STATUS  PORTS  NAMES
        const parts = line.split(/\s{2,}/);
        const name = (parts[parts.length - 1] || "").trim();
        const image = (parts[1] || "").trim();
        const statusIdx = parts.findIndex((p) => /^(Up|Exited|Created|Restarting)/.test(p));
        const rawStatus = statusIdx >= 0 ? parts[statusIdx] : "";
        const { up, healthy, status } = parseDockerHealth(rawStatus);
        return { name, up, healthy, status, image };
      }).filter((c) => c.name);
      if (containers.length > 0) {
        return {
          dockerPs: r.stdout.trim(),
          dockerVersion: "table-fallback",
          disk: "N/A", memory: "N/A", load: "N/A", uptime: "N/A",
          containers,
        };
      }
    }
  } catch { /* fallback */ }

  // Fallback 4: just docker info for version
  log(`table parse failed for ${vmId}, trying docker info`);
  try {
    const r = await sshExecAsync(
      vmId,
      "docker info --format '{{.ServerVersion}}' 2>&1 | head -1",
      8_000, true, 5,
    );
    if (r.ok) {
      const ver = r.stdout.trim();
      return {
        dockerPs: "",
        dockerVersion: isValidDockerVersion(ver) ? ver : "",
        disk: "N/A", memory: "N/A", load: "N/A", uptime: "N/A",
        containers: [],
      };
    }
  } catch { /* fallback */ }

  // Fallback 5: at least get disk/mem/load even without docker
  log(`all docker fallbacks failed for ${vmId}, collecting system info only`);
  try {
    const sysScript = [
      "echo '===disk==='",
      "df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,\"\"); print $5}' || echo N/A",
      "echo '===memory==='",
      "free -m 2>/dev/null | awk '/Mem:/{printf \"%d/%dMB (%.0f%%)\", $3, $2, $3/$2*100}' || echo N/A",
      "echo",
      "echo '===load==='",
      "cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo N/A",
      "echo '===uptime==='",
      "uptime -s 2>/dev/null || echo N/A",
    ].join("\n");
    const r = await sshExecAsync(vmId, sysScript, 8_000, true, 5);
    if (r.ok) {
      return {
        dockerPs: "",
        dockerVersion: "",
        disk: parseSection(r.stdout, "disk"),
        memory: parseSection(r.stdout, "memory"),
        load: parseSection(r.stdout, "load"),
        uptime: parseSection(r.stdout, "uptime"),
        containers: [],
      };
    }
  } catch { /* give up */ }

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
      log(`collectVmBatch rejected for: ${r.reason}`);
    }
  }
  return map;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 1: SELF-CHECK
// ──────────────────────────────────────────────────────────────────────────────

async function layer1SelfCheck(ctx: DiagContext): Promise<Check[]> {
  const checks = await Promise.allSettled([
    timedCheck("C3 API mesh", async () => {
      const r = await runLocal("curl", ["-sf", "--max-time", "3", `${C3_API_MESH}/health`], 5_000);
      if (r.ok) {
        try {
          const body = JSON.parse(r.stdout);
          return { passed: true, details: `${C3_API_MESH} OK (v${body.version ?? "?"})` };
        } catch {
          return { passed: true, details: `${C3_API_MESH} OK` };
        }
      }
      return { passed: false, details: `${C3_API_MESH} unreachable`, severity: "critical" as Severity };
    }),

    timedCheck("C3 API public", async () => {
      const r = await runLocal(
        "curl",
        ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", C3_API_PUBLIC + "/health"],
        8_000,
      );
      const code = r.stdout.trim();
      const ok = ["200", "301", "302"].includes(code);
      return { passed: ok, details: `${C3_API_PUBLIC} -> HTTP ${code}`, severity: ok ? undefined : ("warning" as Severity) };
    }),

    timedCheck("WG interface", async () => {
      const r = await runShell("timeout 3 bash -c 'echo > /dev/tcp/10.0.0.1/22' 2>&1", 5_000);
      return { passed: r.ok, details: r.ok ? "10.0.0.1:22 OK" : "WG DOWN", severity: r.ok ? undefined : ("critical" as Severity) };
    }),

    timedCheck("Local docker", async () => {
      const r = await runShell("docker info --format '{{.ServerVersion}}' 2>&1 | head -1", 5_000);
      if (r.ok && isValidDockerVersion(r.stdout.trim())) {
        return { passed: true, details: `Docker ${r.stdout.trim()}` };
      }
      return { passed: false, details: "docker not available", severity: "info" as Severity };
    }),

    timedCheck("SSH agent", async () => {
      const r = await runShell("ssh-add -l 2>&1 | head -3", 3_000);
      const keys = r.stdout.trim().split("\n").filter((l) => l && !l.includes("no identities")).length;
      if (keys > 0) return { passed: true, details: `${keys} key(s) loaded` };
      const keyCheck = await runShell("test -f ~/.ssh/id_rsa || test -f ~/.ssh/id_ed25519", 2_000);
      return {
        passed: keyCheck.ok,
        details: keyCheck.ok ? "key file present (no agent)" : "no keys found",
        severity: "info" as Severity,
      };
    }),

    timedCheck("cloud-data freshness", async () => {
      const topoPath = join(CLOUD_DATA_DIR, "cloud-data-topology.json");
      if (!existsSync(topoPath)) return { passed: false, details: "cloud-data-topology.json missing", severity: "critical" as Severity };
      try {
        const raw = JSON.parse(readFileSync(topoPath, "utf-8"));
        const gen = raw._generated;
        if (!gen) return { passed: true, details: "no _generated timestamp" };
        const age = Date.now() - new Date(gen).getTime();
        const mins = Math.floor(age / 60000);
        if (mins > 60) return { passed: false, details: `${mins}m stale (> 60m)`, severity: "warning" as Severity };
        return { passed: true, details: `${mins}m old` };
      } catch { return { passed: false, details: "parse error", severity: "warning" as Severity }; }
    }),

    timedCheck("DNS resolver (.app)", async () => {
      // Test that hickory-dns resolves .app domains through WG mesh
      const r = await runShell("timeout 3 dig +short caddy.app @10.0.0.1 2>&1 | head -1", 5_000);
      const ip = r.stdout.trim();
      if (ip && /^\d+\./.test(ip)) return { passed: true, details: `caddy.app -> ${ip}` };
      return { passed: false, details: "hickory-dns not resolving .app domains", severity: "warning" as Severity };
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
          // Also test SSH auth
          const auth = await sshExecAsync(vmId, "echo OK", 8_000, true, 3);
          if (auth.ok) {
            return { passed: true, details: `:22 OK, SSH auth OK` };
          }
          return { passed: true, details: `:22 OK, SSH auth FAILED: ${auth.stderr.split("\n").pop()?.trim() || "unknown"}`, severity: "warning" as Severity };
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
    if (data.dockerVersion && data.dockerVersion !== "fallback" && data.dockerVersion !== "detected" && data.dockerVersion !== "table-fallback") {
      ctx.dockerOkVms.add(vmId);
    } else if (data.containers.length > 0) {
      ctx.dockerOkVms.add(vmId);
    }

    const diskPct = parseInt(data.disk);
    const diskSev = !isNaN(diskPct) && diskPct >= 90 ? "critical" : !isNaN(diskPct) && diskPct >= 80 ? "warning" : undefined;
    const diskStr = !isNaN(diskPct) ? `${diskPct}%` : data.disk;
    const containerCount = data.containers.length;
    const unhealthyCount = data.containers.filter((c) => c.healthy === false).length;
    const exitedCount = data.containers.filter((c) => !c.up).length;
    const runningCount = data.containers.filter((c) => c.up).length;

    const parts: string[] = [];
    if (data.dockerVersion) parts.push(`Docker ${data.dockerVersion}`);
    else parts.push("Docker N/A");
    parts.push(`${runningCount}/${containerCount} running`);
    if (unhealthyCount > 0) parts.push(`${unhealthyCount} unhealthy`);
    if (exitedCount > 0) parts.push(`${exitedCount} exited`);
    parts.push(`disk:${diskStr}`, `mem:${data.memory}`, `load:${data.load}`);

    const passed = containerCount > 0 && unhealthyCount === 0 && (diskSev !== "critical");
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
      // Skip internal-only domains
      if (svc.domain === "dns.internal") continue;
      domainChecks.push({ name, domain: svc.domain });
    }
  }

  // Add caddy route domains not already covered
  const svcDomains = new Set(domainChecks.map((d) => d.domain));
  for (const route of ctx.caddyRoutes) {
    if (route.domain && !svcDomains.has(route.domain) && route.type !== "special" && !route.domain.includes("internal")) {
      domainChecks.push({ name: `route:${route.domain}`, domain: route.domain });
    }
  }

  const results = await Promise.allSettled(
    domainChecks.map(({ name, domain }) =>
      timedCheck(name, async () => {
        // Handle path-based routes
        let url: string;
        if (domain.startsWith("http")) {
          url = domain;
        } else if (domain.includes("/")) {
          // Path route like "api.diegonmarcos.com/c3-api"
          url = `https://${domain}`;
        } else {
          url = `https://${domain}`;
        }
        const r = await runLocal(
          "curl",
          ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", ...authArgs, url],
          8_000,
        );
        const code = r.stdout.trim();
        // 200-399 = good, 401/403 = auth-protected (expected)
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
// LAYER 6: PRIVATE URLS (curl services via WG mesh using wg_ip:port)
// ──────────────────────────────────────────────────────────────────────────────

async function layer6PrivateUrls(ctx: DiagContext): Promise<Check[]> {
  // Build list of services with domain + port + VM with WG IP
  const targets: { name: string; wgIp: string; port: number; domain: string }[] = [];

  for (const [name, svc] of Object.entries(ctx.services)) {
    if (!svc.domain || svc.vm === "local" || svc.frozen) continue;
    if (svc.domain === "dns.internal") continue;

    const port = ctx.servicePorts.get(name);
    if (!port) continue;

    const wgIp = vmWgIp(ctx, svc.vm);
    if (!wgIp) continue;

    targets.push({ name, wgIp, port, domain: svc.domain });
  }

  if (targets.length === 0) {
    return [{
      name: "private URL scan",
      passed: true,
      details: "no services with ports found (build.json missing?)",
      durationMs: 0,
      severity: "info",
    }];
  }

  const results = await Promise.allSettled(
    targets.map(({ name, wgIp, port, domain }) =>
      timedCheck(`${name} (${wgIp}:${port})`, async () => {
        // Try HTTP on the WG mesh IP:port
        const r = await runLocal(
          "curl",
          ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", `http://${wgIp}:${port}/`],
          5_000,
        );
        const code = r.stdout.trim();
        if (/^[23]\d\d$/.test(code) || ["401", "403"].includes(code)) {
          return { passed: true, details: `${wgIp}:${port} -> ${code}` };
        }
        // Fallback: TCP probe
        const tcp = await runShell(`timeout 2 bash -c 'echo > /dev/tcp/${wgIp}/${port}' 2>&1`, 4_000);
        if (tcp.ok) {
          return { passed: true, details: `${wgIp}:${port} TCP OK (HTTP ${code})` };
        }
        return { passed: false, details: `${wgIp}:${port} unreachable (HTTP ${code})`, severity: "warning" as Severity };
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
// LAYER 7: CROSS-CHECKS (public URL health vs container health)
// ──────────────────────────────────────────────────────────────────────────────

async function layer7CrossChecks(ctx: DiagContext): Promise<Check[]> {
  const bearer = ctx.bearerToken;
  const authArgs = bearer ? ["-H", `Authorization: Bearer ${bearer}`] : [];
  const checks: Check[] = [];

  for (const [name, svc] of Object.entries(ctx.services)) {
    if (!svc.domain || svc.vm === "local" || svc.frozen) continue;
    if (svc.domain === "dns.internal") continue;
    const containers = svc.containers ?? [];
    if (containers.length === 0) continue;

    // Get container health from vmBatch
    const vmData = ctx.vmBatch.get(svc.vm);
    const mainContainer = containers[0];
    const c = vmData ? findContainer(vmData.containers, mainContainer) : null;
    const containerUp = c?.up ?? false;
    const containerHealthy = c?.healthy;

    // Get public URL status
    const url = svc.domain.startsWith("http") ? svc.domain : `https://${svc.domain}`;
    let pubCode = "N/A";
    try {
      const r = await runLocal(
        "curl",
        ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "4", ...authArgs, url],
        6_000,
      );
      pubCode = r.stdout.trim();
    } catch { /* timeout */ }

    // Get private URL status (if port known)
    const port = ctx.servicePorts.get(name);
    const wgIp = vmWgIp(ctx, svc.vm);
    let privOk = false;
    let privDetail = "no port";
    if (port && wgIp) {
      try {
        const r = await runLocal(
          "curl",
          ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", `http://${wgIp}:${port}/`],
          5_000,
        );
        const code = r.stdout.trim();
        privOk = /^[23]\d\d$/.test(code) || ["401", "403"].includes(code);
        privDetail = `${wgIp}:${port}->${code}`;
      } catch {
        privDetail = "timeout";
      }
    }

    const pubOk = /^[23]\d\d$/.test(pubCode) || ["401", "403"].includes(pubCode);
    const containerStatus = !vmData ? "offline" : !c ? "missing" : !containerUp ? "down" : containerHealthy === false ? "unhealthy" : "ok";

    // Cross-check verdict
    let passed: boolean;
    let details: string;
    let severity: Severity | undefined;

    if (pubOk && containerStatus === "ok") {
      passed = true;
      details = `pub:${pubCode} container:${containerStatus} priv:${privDetail}`;
    } else if (!pubOk && containerStatus === "ok" && privOk) {
      passed = false;
      details = `pub:${pubCode} container:OK priv:OK -- Caddy/Authelia routing issue`;
      severity = "warning";
    } else if (pubOk && containerStatus !== "ok") {
      passed = false;
      details = `pub:${pubCode} container:${containerStatus} -- stale cache or wrong backend`;
      severity = "warning";
    } else if (containerStatus === "offline") {
      passed = false;
      details = `pub:${pubCode} container:${containerStatus} -- VM offline`;
      severity = "warning";
    } else {
      passed = false;
      details = `pub:${pubCode} container:${containerStatus} priv:${privDetail} -- service DOWN`;
      severity = "critical";
    }

    checks.push({ name, passed, details, durationMs: 0, severity });
  }

  return checks;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 8: EXTERNAL
// ──────────────────────────────────────────────────────────────────────────────

async function layer8External(_ctx: DiagContext): Promise<Check[]> {
  const results = await Promise.allSettled([
    timedCheck("Cloudflare DNS", async () => {
      const r = await runShell("dig +short diegonmarcos.com @1.1.1.1 2>&1 | head -1", 5_000);
      const ip = r.stdout.trim();
      return { passed: ip.length > 0 && !ip.includes("error"), details: ip || "FAIL", severity: "critical" as Severity };
    }),

    timedCheck("GHCR registry", async () => {
      const r = await runLocal("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://ghcr.io/v2/"], 8_000);
      const ok = ["200", "401"].includes(r.stdout.trim());
      return { passed: ok, details: `HTTP ${r.stdout.trim()}`, severity: "warning" as Severity };
    }),

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

    timedCheck("Resend API", async () => {
      const r = await runLocal("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://api.resend.com/health"], 8_000);
      const code = r.stdout.trim();
      return { passed: code === "200", details: `HTTP ${code}`, severity: "info" as Severity };
    }),

    timedCheck("GitHub API", async () => {
      const r = await runLocal("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://api.github.com"], 8_000);
      const code = r.stdout.trim();
      const ok = ["200", "403"].includes(code); // 403 = rate limited but reachable
      return { passed: ok, details: `HTTP ${code}`, severity: "info" as Severity };
    }),

    timedCheck("Cloudflare DNS (MX)", async () => {
      const r = await runShell("dig +short MX diegonmarcos.com @1.1.1.1 2>&1 | head -1", 5_000);
      const mx = r.stdout.trim();
      return { passed: mx.length > 0, details: mx || "no MX record", severity: "warning" as Severity };
    }),

    timedCheck("Cloudflare DNS (A mail)", async () => {
      const r = await runShell("dig +short A mail.diegonmarcos.com @1.1.1.1 2>&1 | head -1", 5_000);
      const ip = r.stdout.trim();
      return { passed: ip.length > 0, details: ip || "no A record", severity: "warning" as Severity };
    }),

    timedCheck("DKIM DNS", async () => {
      const r = await runShell("dig +short TXT dkim._domainkey.diegonmarcos.com @1.1.1.1 2>&1 | head -1", 5_000);
      const txt = r.stdout.trim();
      return { passed: txt.includes("v=DKIM1") || txt.length > 20, details: txt ? "DKIM present" : "missing", severity: "warning" as Severity };
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
    passed: extra.length <= 2,
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

  // 9d: Exited containers (running containers that are stopped)
  const exited: string[] = [];
  for (const [vmId, data] of Array.from(ctx.vmBatch)) {
    if (!data) continue;
    for (const c of data.containers) {
      if (!c.up) exited.push(`${getAlias(ctx, vmId)}/${c.name}`);
    }
  }
  checks.push({
    name: "Exited containers",
    passed: exited.length === 0,
    details:
      exited.length === 0
        ? "no exited containers"
        : `${exited.length} exited: ${exited.slice(0, 8).join(", ")}${exited.length > 8 ? "..." : ""}`,
    durationMs: 0,
    severity: exited.length > 0 ? "warning" : undefined,
  });

  // 9e: Services without containers declaration in topology
  const noContainers: string[] = [];
  for (const [name, svc] of Object.entries(ctx.services)) {
    if (!svc.vm || svc.vm === "local" || svc.frozen) continue;
    if (!svc.containers || svc.containers.length === 0) {
      noContainers.push(name);
    }
  }
  checks.push({
    name: "Services without containers",
    passed: noContainers.length <= 3,
    details:
      noContainers.length === 0
        ? "all services declare containers"
        : `${noContainers.length}: ${noContainers.slice(0, 5).join(", ")}`,
    durationMs: 0,
    severity: noContainers.length > 3 ? "info" : undefined,
  });

  // 9f: Services without domain
  const noDomain: string[] = [];
  for (const [name, svc] of Object.entries(ctx.services)) {
    if (svc.vm === "local" || svc.frozen) continue;
    if (!svc.domain) noDomain.push(name);
  }
  checks.push({
    name: "Services without domain",
    passed: true, // informational
    details: noDomain.length === 0
      ? "all services have domains"
      : `${noDomain.length}: ${noDomain.slice(0, 5).join(", ")}`,
    durationMs: 0,
    severity: "info",
  });

  // 9g: Services without port in build.json
  const noPort: string[] = [];
  for (const [name, svc] of Object.entries(ctx.services)) {
    if (svc.vm === "local" || svc.frozen) continue;
    if (svc.domain && !ctx.servicePorts.has(name)) noPort.push(name);
  }
  checks.push({
    name: "Services missing port (build.json)",
    passed: noPort.length <= 2,
    details: noPort.length === 0
      ? "all domain services have ports in build.json"
      : `${noPort.length}: ${noPort.slice(0, 5).join(", ")}`,
    durationMs: 0,
    severity: noPort.length > 2 ? "info" : undefined,
  });

  return checks;
}

// ──────────────────────────────────────────────────────────────────────────────
// LAYER 10: SECURITY
// ──────────────────────────────────────────────────────────────────────────────

async function layer10Security(ctx: DiagContext): Promise<Check[]> {
  const keyDomains = ["diegonmarcos.com", "auth.diegonmarcos.com", "api.diegonmarcos.com", "mail.diegonmarcos.com"];

  const results = await Promise.allSettled([
    // TLS cert expiry on key domains
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

    timedCheck("DMARC DNS", async () => {
      const r = await runShell("dig +short TXT _dmarc.diegonmarcos.com 2>&1 | head -1", 5_000);
      const txt = r.stdout.trim();
      const ok = txt.includes("v=DMARC1");
      return { passed: ok, details: ok ? "DMARC1 present" : `missing: ${txt || "no record"}`, severity: ok ? undefined : ("warning" as Severity) };
    }),

    timedCheck("SPF DNS", async () => {
      const r = await runShell("dig +short TXT diegonmarcos.com 2>&1", 5_000);
      const ok = r.stdout.includes("v=spf1");
      return { passed: ok, details: ok ? "SPF present" : "missing", severity: ok ? undefined : ("warning" as Severity) };
    }),

    timedCheck("Authelia health", async () => {
      const r = await runLocal(
        "curl",
        ["-sf", "--max-time", "3", "https://auth.diegonmarcos.com/api/health"],
        5_000,
      );
      if (r.ok) return { passed: true, details: "healthy" };
      // Fallback: check container
      const proxyData = ctx.vmBatch.get("gcp-E2-f_0");
      if (proxyData) {
        const c = findContainer(proxyData.containers, "authelia");
        if (c?.up && c.healthy !== false) return { passed: true, details: `container ${c.status}` };
      }
      return { passed: false, details: "unreachable", severity: "critical" as Severity };
    }),

    timedCheck("Firewall ports", async () => {
      const proxyIp = ctx.vms["gcp-E2-f_0"]?.ip;
      if (!proxyIp) return { passed: true, details: "no proxy IP (skipped)", severity: "info" as Severity };
      const dangerousPorts = [6379, 5432, 3306, 8081]; // Redis, Postgres, MySQL, C3 API
      const openPorts: number[] = [];
      for (const port of dangerousPorts) {
        const r = await runShell(`timeout 2 bash -c 'echo > /dev/tcp/${proxyIp}/${port}' 2>&1`, 4_000);
        if (r.ok) openPorts.push(port);
      }
      if (openPorts.length === 0) return { passed: true, details: "no dangerous ports open on public IP" };
      return { passed: false, details: `unexpected open: ${openPorts.join(", ")}`, severity: "critical" as Severity };
    }),

    timedCheck("SSH host key stability", async () => {
      // Check that known_hosts has entries for all VMs
      const missingKeys: string[] = [];
      for (const [vmId, vm] of getActiveVms(ctx)) {
        if (!vm.ip || vm.ip === "TBD") continue;
        const r = await runShell(`ssh-keygen -F ${vm.ip} 2>/dev/null | head -1`, 3_000);
        if (!r.stdout.trim()) missingKeys.push(vm.ssh_alias ?? vmId);
      }
      if (missingKeys.length === 0) return { passed: true, details: "all VM host keys in known_hosts" };
      return { passed: false, details: `missing keys: ${missingKeys.join(", ")}`, severity: "warning" as Severity };
    }),

    timedCheck("Caddy TLS (proxy)", async () => {
      // Verify Caddy is serving valid TLS on the proxy
      const r = await runShell(
        "echo | openssl s_client -servername proxy.diegonmarcos.com -connect proxy.diegonmarcos.com:443 2>&1 | grep 'Verify return code'",
        8_000,
      );
      const ok = r.stdout.includes("return code: 0");
      return { passed: ok, details: ok ? "TLS valid" : r.stdout.trim().slice(0, 60) || "check failed", severity: ok ? undefined : ("warning" as Severity) };
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
    servicePorts: loadServicePorts(),
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
    "obs.health.cloud_up",
    "Quick infrastructure UP check: self-check + WG mesh + platform (~10s)",
    {},
    () =>
      safeRun(async () => {
        const ctx = buildContext();
        const t0 = performance.now();
        const marks: { layer: string; ms: number }[] = [];
        const sections: string[] = [];

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
    "obs.health.cloud",
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
            chain.push("gcp-proxy: Docker unreachable -> proxy status unknown");
          } else {
            chain.push("gcp-proxy unreachable -> ALL public services affected");
          }

          // VMs with SSH auth failure
          const authFailed = getActiveVms(ctx).filter(([id]) =>
            ctx.reachableVms.has(id) && !ctx.sshOkVms.has(id)
          );
          if (authFailed.length > 0) {
            chain.push(`SSH auth failed: ${authFailed.map(([_, v]) => v.ssh_alias ?? "?").join(", ")} -> containers unknown`);
          }

          // Docker daemon down
          const dockerDown = Array.from(ctx.sshOkVms).filter((id) => !ctx.dockerOkVms.has(id));
          if (dockerDown.length > 0) {
            chain.push(`Docker daemon down: ${dockerDown.map((id) => getAlias(ctx, id)).join(", ")}`);
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

  // ── health_cloud_resources: Full VM + database resource profiling ──────────
  server.tool(
    "obs.resources.all",
    "Full resource profiling: all VMs (CPU, RAM, disk, swap, processes) + all databases (size, connections, tables)",
    {},
    () => safeRun(async () => {
      const topo = loadTopology();
      const activeVms = Object.entries(topo.vms).filter(([_, v]) => v.wg_ip && v.ip !== "TBD");
      const sections: string[] = [];

      // Collect all VM resources in parallel
      const vmResults = await Promise.allSettled(
        activeVms.map(async ([vmId, vm]) => {
          const alias = vm.ssh_alias ?? vmId;
          const data = await collectVmResources(vmId);
          return { vmId, alias, data };
        }),
      );

      sections.push("VM RESOURCES");
      sections.push("═".repeat(70));
      for (const r of vmResults) {
        if (r.status !== "fulfilled") continue;
        const { alias, data } = r.value;
        if (!data) { sections.push(`\n${alias}: UNREACHABLE`); continue; }
        sections.push(`\n── ${alias} ──`);
        sections.push(data);
      }

      // Collect all database sizes in parallel
      sections.push("\n\nDATABASE RESOURCES");
      sections.push("═".repeat(70));

      const dbServices = Object.entries(topo.services).filter(([_, s]) =>
        s.containers?.some((c) => /postgres|mariadb|mysql|redis|sqlite|nocodb.db/i.test(c))
      );

      const dbResults = await Promise.allSettled(
        dbServices.map(async ([name, svc]) => {
          const data = await collectDbResources(svc.vm, svc.containers ?? [], name);
          return { name, vm: svc.vm, data };
        }),
      );

      for (const r of dbResults) {
        if (r.status !== "fulfilled") continue;
        const { name, vm, data } = r.value;
        const alias = topo.vms[vm]?.ssh_alias ?? vm;
        sections.push(`\n── ${name} (${alias}) ──`);
        sections.push(data);
      }

      return sections.join("\n");
    }),
  );

  // ── health_cloud_resources_vm: Single VM deep profiling ──────────────────
  server.tool(
    "obs.resources.vm",
    "Deep resource profile for a single VM: CPU, RAM, disk, swap, top processes, docker stats",
    { vm: z.string().describe("VM ID or alias (e.g. oci-apps, gcp-proxy)") },
    ({ vm }) => safeRun(async () => {
      const data = await collectVmResources(vm);
      return `VM RESOURCES: ${vm}\n${"═".repeat(70)}\n${data}`;
    }),
  );

  // ── health_cloud_resources_db: Single database profiling ──────────────────
  server.tool(
    "obs.resources.db",
    "Database resource profile: size, connections, tables, slow queries",
    {
      service: z.string().describe("Service name (e.g. etherpad, nocodb, hedgedoc, matomo)"),
    },
    ({ service }) => safeRun(async () => {
      const topo = loadTopology();
      const svc = topo.services[service];
      if (!svc) return `Service not found: ${service}`;
      const data = await collectDbResources(svc.vm, svc.containers ?? [], service);
      return `DATABASE RESOURCES: ${service}\n${"═".repeat(70)}\n${data}`;
    }),
  );
}

// ── Resource collection helpers ──────────────────────────────────────────────

async function collectVmResources(vmId: string): Promise<string> {
  const script = [
    "echo '=== SYSTEM ==='",
    "uname -a 2>/dev/null | head -1",
    "echo '=== CPU ==='",
    "nproc 2>/dev/null; cat /proc/loadavg 2>/dev/null",
    "echo '=== MEMORY ==='",
    "free -h 2>/dev/null",
    "echo '=== SWAP ==='",
    "swapon --show 2>/dev/null || echo 'no swap'",
    "echo '=== DISK ==='",
    "df -h / /var /tmp 2>/dev/null | sort -u",
    "echo '=== DOCKER DISK ==='",
    "docker system df 2>/dev/null || echo 'docker unavailable'",
    "echo '=== TOP PROCESSES ==='",
    "ps aux --sort=-%mem 2>/dev/null | head -11",
    "echo '=== DOCKER STATS ==='",
    "timeout 3 docker stats --no-stream --format 'table {{.Name}}\\t{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.NetIO}}\\t{{.BlockIO}}' 2>/dev/null | head -20 || echo 'docker unavailable'",
    "echo '=== UPTIME ==='",
    "uptime 2>/dev/null",
  ].join("\n");

  try {
    const r = await sshExecAsync(vmId, script, 15_000, true, 5);
    if (r.ok || r.stdout.length > 50) return r.stdout.trim();
    return `SSH failed: ${r.stderr.trim().split("\n").pop() || "unknown error"}`;
  } catch (e) {
    return `Error: ${e instanceof Error ? e.message : String(e)}`;
  }
}

async function collectDbResources(vmId: string, containers: string[], serviceName: string): Promise<string> {
  const dbContainer = containers.find((c) => /postgres|mariadb|mysql|db/i.test(c));
  if (!dbContainer) return "no database container detected";

  const isPostgres = /postgres/i.test(dbContainer);
  const isMariadb = /mariadb|mysql/i.test(dbContainer);
  const isRedis = /redis/i.test(dbContainer);

  let query: string;
  if (isPostgres) {
    query = [
      `docker exec ${dbContainer} psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;" 2>&1`,
      `docker exec ${dbContainer} psql -U postgres -c "SELECT count(*) AS active_connections FROM pg_stat_activity;" 2>&1`,
      `docker exec ${dbContainer} psql -U postgres -c "SELECT schemaname, count(*) AS tables FROM pg_tables GROUP BY schemaname;" 2>&1`,
    ].join("\necho '---'\n");
  } else if (isMariadb) {
    query = [
      `docker exec ${dbContainer} mysql -u root -e "SELECT table_schema AS db, ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS size_mb FROM information_schema.tables GROUP BY table_schema;" 2>&1`,
      `docker exec ${dbContainer} mysql -u root -e "SHOW PROCESSLIST;" 2>&1`,
    ].join("\necho '---'\n");
  } else if (isRedis) {
    query = `docker exec ${dbContainer} redis-cli INFO memory 2>&1 | head -20`;
  } else {
    query = `docker inspect ${dbContainer} --format '{{.State.Status}} since {{.State.StartedAt}}' 2>&1`;
  }

  try {
    const r = await sshExecAsync(vmId, query, 10_000, true, 5);
    return r.stdout.trim() || r.stderr.trim() || "no output";
  } catch (e) {
    return `Error: ${e instanceof Error ? e.message : String(e)}`;
  }
}

// ── Standalone runner (GHA / CLI) ────────────────────────────────────────────
if (process.argv[1]?.endsWith("health_cloud.ts") || process.argv[1]?.endsWith("health_cloud.js")) {
  const mode = process.argv[2] === "quick" ? "obs.health.cloud_up" : "obs.health.cloud";
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
