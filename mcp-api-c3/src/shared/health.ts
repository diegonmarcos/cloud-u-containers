import { sshExec, checkVmReachable } from "./ssh.js";
import { getConfig, resolveVmId, getVmSshAlias, getServicesForVm } from "./config.js";
import { listContainers } from "./docker.js";
import { exec } from "./exec.js";
import type { VmConfig, ServiceConfig } from "./types.js";

// ── Types ────────────────────────────────────────────────────────────────

export interface Tier1Result {
  vm: string;
  alias: string;
  ip: string;
  reachable: boolean;
  latencyMs?: number;
  error?: string;
}

export interface Tier2Result extends Tier1Result {
  sshOk?: boolean;
  sshError?: string;
}

export interface VmResources {
  uptime?: string;
  memoryTotal?: string;
  memoryUsed?: string;
  memoryFree?: string;
  diskTotal?: string;
  diskUsed?: string;
  diskAvailable?: string;
  diskPercent?: string;
}

export interface ContainerInfo {
  name: string;
  status: string;
  image?: string;
  ports?: string;
}

export interface Tier3Result extends Tier2Result {
  resources?: VmResources;
  containers?: ContainerInfo[];
}

export interface DeployedVm {
  vm: string;
  alias: string;
  containers: ContainerInfo[];
  error?: string;
}

export interface DriftEntry {
  service: string;
  declared: boolean;
  deployed: boolean;
  status: "ok" | "missing" | "extra" | "unknown";
}

export interface HealthDeclaredResult {
  vms: Record<string, VmConfig>;
  services: Record<string, ServiceConfig>;
  vmCount: number;
  serviceCount: number;
}

export interface HealthStatusResult {
  declared: HealthDeclaredResult;
  deployed: DeployedVm[];
  drift: DriftEntry[];
}

// ── Helpers ──────────────────────────────────────────────────────────────

function getVmIds(vmId?: string): string[] {
  if (vmId) {
    const resolved = resolveVmId(vmId);
    return [resolved];
  }
  const config = getConfig();
  return Object.keys(config.vms);
}

function parseResources(output: string): VmResources {
  const resources: VmResources = {};

  // Split by markers
  const memMarker = "===MEM===";
  const diskMarker = "===DISK===";

  const memIdx = output.indexOf(memMarker);
  const diskIdx = output.indexOf(diskMarker);

  // Parse uptime (everything before ===MEM===)
  if (memIdx > 0) {
    resources.uptime = output.slice(0, memIdx).trim();
  }

  // Parse free -h output (between ===MEM=== and ===DISK===)
  if (memIdx >= 0 && diskIdx > memIdx) {
    const memBlock = output.slice(memIdx + memMarker.length, diskIdx).trim();
    const lines = memBlock.split("\n");
    // Find the "Mem:" line
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith("Mem:")) {
        //  Mem:   total   used   free   shared   buff/cache   available
        const parts = trimmed.split(/\s+/);
        if (parts.length >= 4) {
          resources.memoryTotal = parts[1];
          resources.memoryUsed = parts[2];
          resources.memoryFree = parts[3];
        }
        break;
      }
    }
  }

  // Parse df -h / output (after ===DISK===)
  if (diskIdx >= 0) {
    const diskBlock = output.slice(diskIdx + diskMarker.length).trim();
    const lines = diskBlock.split("\n");
    // Skip header, find the data line (usually line 1, but could wrap)
    for (let i = 1; i < lines.length; i++) {
      const trimmed = lines[i].trim();
      if (!trimmed) continue;
      const parts = trimmed.split(/\s+/);
      // Format: Filesystem Size Used Avail Use% Mounted
      if (parts.length >= 5) {
        resources.diskTotal = parts[1];
        resources.diskUsed = parts[2];
        resources.diskAvailable = parts[3];
        resources.diskPercent = parts[4];
        break;
      }
    }
  }

  return resources;
}

// ── Exported Functions ───────────────────────────────────────────────────

/**
 * Simple heartbeat. This MCP server IS the API now (replaces Rust API health.rs).
 */
export function healthAlive(): { status: string; version: string } {
  return { status: "ok", version: "3.0.0" };
}

/**
 * Returns declared VMs and services from cloud-topology.json. No network probing.
 */
export function healthDeclared(): HealthDeclaredResult {
  const config = getConfig();
  return {
    vms: config.vms,
    services: config.services,
    vmCount: Object.keys(config.vms).length,
    serviceCount: Object.keys(config.services).length,
  };
}

/**
 * For each VM (or a single VM), SSH in and run docker ps to get live containers.
 */
export function healthDeployed(vmId?: string): DeployedVm[] {
  const vmIds = getVmIds(vmId);
  const results: DeployedVm[] = [];

  for (const id of vmIds) {
    const alias = getVmSshAlias(id);
    try {
      const { containers, ok, raw } = listContainers(id);
      if (!ok) {
        results.push({ vm: id, alias, containers: [], error: raw });
      } else {
        const mapped: ContainerInfo[] = containers.map((c) => ({
          name: c.name ?? "",
          status: c.status ?? "",
          image: c.image,
          ports: c.ports,
        }));
        results.push({ vm: id, alias, containers: mapped });
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      results.push({ vm: id, alias, containers: [], error: message });
    }
  }

  return results;
}

/**
 * Compare declared services (cloud-topology.json) with deployed containers (docker ps).
 * For each service, check if expected containers are running.
 */
export function healthDrift(): DriftEntry[] {
  const config = getConfig();
  const drift: DriftEntry[] = [];

  // Gather all deployed containers indexed by VM
  const deployedByVm = new Map<string, Set<string>>();
  const allContainerNames = new Set<string>();

  for (const vmId of Object.keys(config.vms)) {
    try {
      const { containers, ok } = listContainers(vmId, true);
      if (ok) {
        const names = new Set(containers.map((c) => c.name ?? ""));
        deployedByVm.set(vmId, names);
        Array.from(names).forEach((name) => {
          allContainerNames.add(name);
        });
      }
    } catch {
      // VM unreachable -- skip, we will mark its services as "unknown"
    }
  }

  // Track which container names are accounted for by declared services
  const accountedContainers = new Set<string>();

  // Check each declared service
  for (const [serviceName, svc] of Object.entries(config.services)) {
    const vmId = svc.vm;

    // Skip local-only or "all" services -- not deployed as containers
    if (vmId === "local" || vmId === "all") {
      continue;
    }

    const vmContainers = deployedByVm.get(vmId);

    if (!vmContainers) {
      // VM was unreachable, cannot determine status
      drift.push({
        service: serviceName,
        declared: true,
        deployed: false,
        status: "unknown",
      });
      continue;
    }

    // A service is considered "deployed" if any container name contains the service name
    const matchingContainers = Array.from(vmContainers).filter((name) =>
      name.includes(serviceName)
    );
    const isDeployed = matchingContainers.length > 0;

    for (const name of matchingContainers) {
      accountedContainers.add(name);
    }

    drift.push({
      service: serviceName,
      declared: true,
      deployed: isDeployed,
      status: isDeployed ? "ok" : "missing",
    });
  }

  // Find "extra" containers: deployed but not declared
  for (const containerName of Array.from(allContainerNames)) {
    if (!accountedContainers.has(containerName)) {
      drift.push({
        service: containerName,
        declared: false,
        deployed: true,
        status: "extra",
      });
    }
  }

  return drift;
}

/**
 * Combined view: declared + deployed + drift in one call.
 */
export function healthStatus(vmId?: string): HealthStatusResult {
  const declared = healthDeclared();
  const deployed = healthDeployed(vmId);

  // For drift, we always check all VMs to get the full picture,
  // but if vmId is specified we filter the drift entries to relevant services
  let drift: DriftEntry[];
  if (vmId) {
    const resolvedVm = resolveVmId(vmId);
    const vmServiceNames = new Set(
      getServicesForVm(resolvedVm).map(([name]) => name)
    );
    const fullDrift = healthDrift();
    drift = fullDrift.filter((entry) => vmServiceNames.has(entry.service));
  } else {
    drift = healthDrift();
  }

  return { declared, deployed, drift };
}

/**
 * Tier 1: Quick TCP/SSH-keyscan check (no auth, fast).
 * Uses ssh-keyscan which does a TCP handshake + SSH banner exchange.
 */
export function checkTier1All(vmId?: string): Tier1Result[] {
  const vmIds = getVmIds(vmId);
  const config = getConfig();
  const results: Tier1Result[] = [];

  for (const id of vmIds) {
    const alias = getVmSshAlias(id);
    const vmConfig = config.vms[id];
    const ip = vmConfig?.ip ?? "unknown";

    const start = Date.now();
    try {
      const result = checkVmReachable(id);
      const latencyMs = Date.now() - start;

      results.push({
        vm: id,
        alias,
        ip,
        reachable: result.ok,
        latencyMs,
        ...(result.ok ? {} : { error: result.stderr.trim() || "keyscan failed" }),
      });
    } catch (err) {
      const latencyMs = Date.now() - start;
      const message = err instanceof Error ? err.message : String(err);
      results.push({
        vm: id,
        alias,
        ip,
        reachable: false,
        latencyMs,
        error: message,
      });
    }
  }

  return results;
}

/**
 * Tier 2: SSH session check (full authentication).
 * For each VM, runs `ssh <alias> true` to verify a full SSH session works.
 */
export function checkTier2All(vmId?: string): Tier2Result[] {
  const tier1Results = checkTier1All(vmId);
  const results: Tier2Result[] = [];

  for (const t1 of tier1Results) {
    if (!t1.reachable) {
      // Skip SSH auth check if TCP is unreachable
      results.push({ ...t1, sshOk: false, sshError: "VM unreachable (tier1 failed)" });
      continue;
    }

    try {
      const sshResult = sshExec(t1.vm, "true", 15_000);
      results.push({
        ...t1,
        sshOk: sshResult.ok,
        ...(sshResult.ok ? {} : { sshError: sshResult.stderr.trim() || `exit ${sshResult.exitCode}` }),
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      results.push({ ...t1, sshOk: false, sshError: message });
    }
  }

  return results;
}

/**
 * Tier 3: Full probe -- SSH in and get resources (uptime, memory, disk) + docker ps.
 */
export function checkTier3All(vmId?: string): Tier3Result[] {
  const tier2Results = checkTier2All(vmId);
  const results: Tier3Result[] = [];

  for (const t2 of tier2Results) {
    if (!t2.sshOk) {
      results.push({ ...t2 });
      continue;
    }

    try {
      const resources = gatherVmResources(t2.vm);
      const { containers } = listContainers(t2.vm);
      const containerInfos: ContainerInfo[] = containers.map((c) => ({
        name: c.name ?? "",
        status: c.status ?? "",
        image: c.image,
        ports: c.ports,
      }));

      results.push({ ...t2, resources, containers: containerInfos });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      results.push({ ...t2, error: message });
    }
  }

  return results;
}

/**
 * SSH into a VM and gather resource usage: uptime, memory (free -h), and disk (df -h /).
 */
export function gatherVmResources(vmId: string): VmResources {
  const resolved = resolveVmId(vmId);
  const cmd = 'uptime && echo "===MEM===" && free -h && echo "===DISK===" && df -h /';
  const result = sshExec(resolved, cmd, 15_000);

  if (!result.ok) {
    return { uptime: `(failed: exit ${result.exitCode})` };
  }

  return parseResources(result.stdout);
}

/**
 * Run tier1 + tier2 + tier3 for a single VM. Returns the combined result.
 */
export function probeVm(vmId: string): Tier3Result {
  const results = checkTier3All(vmId);
  if (results.length === 0) {
    const resolved = resolveVmId(vmId);
    const alias = getVmSshAlias(resolved);
    const config = getConfig();
    const ip = config.vms[resolved]?.ip ?? "unknown";
    return {
      vm: resolved,
      alias,
      ip,
      reachable: false,
      error: "No results returned from tier3 check",
    };
  }
  return results[0];
}

// ── New: Application-level health endpoints ──────────────────────────────

// Service-specific health paths. If a service isn't here, we skip it.
const HEALTH_PATHS: Record<string, string> = {
  authelia: "/api/health",
  vaultwarden: "/alive",
  ntfy: "/v1/health",
  matomo: "/index.php?module=API&method=API.getMatomoVersion&format=json",
  syncthing: "/rest/noauth/health",
  photoprism: "/api/v1/status",
  nocodb: "/api/v1/health",
  windmill: "/api/version",
};

// Known service domains (duplicated from discovery for independence)
const HEALTH_DOMAINS: Record<string, string> = {
  authelia: "auth.diegonmarcos.com",
  vaultwarden: "vault.diegonmarcos.com",
  ntfy: "rss.diegonmarcos.com",
  matomo: "analytics.diegonmarcos.com",
  syncthing: "sync.diegonmarcos.com",
  photoprism: "photos.diegonmarcos.com",
  nocodb: "db.diegonmarcos.com",
  windmill: "windmill.diegonmarcos.com",
};

export interface EndpointHealthResult {
  service: string;
  domain: string;
  path: string;
  statusCode: number;
  responseTimeMs: number;
  ok: boolean;
  error?: string;
}

export function healthEndpoints(): EndpointHealthResult[] {
  const results: EndpointHealthResult[] = [];

  for (const [service, path] of Object.entries(HEALTH_PATHS)) {
    const domain = HEALTH_DOMAINS[service];
    if (!domain) continue;

    const url = `https://${domain}${path}`;
    const start = Date.now();

    const result = exec("curl", [
      "-s", "-o", "/dev/null",
      "-w", "%{http_code}",
      "-m", "10",
      url,
    ], { timeout: 15_000 });

    const responseTimeMs = Date.now() - start;
    const statusCode = parseInt(result.stdout.trim(), 10) || 0;

    results.push({
      service,
      domain,
      path,
      statusCode,
      responseTimeMs,
      ok: statusCode >= 200 && statusCode < 400,
      ...(statusCode === 0 ? { error: result.stderr.trim() || "Connection failed" } : {}),
    });
  }

  return results;
}

// ── Generic /up and /health for any target (VM, service, container) ─────

export interface UpResult {
  target: string;
  type: "vm" | "service" | "container";
  up: boolean;
  latencyMs: number;
  details?: string;
  error?: string;
}

export interface HealthResult extends UpResult {
  healthy: boolean;
  status?: string;
  info?: Record<string, unknown>;
}

/**
 * Resolve a target name to its type and VM.
 * Priority: VM alias/id → service name → container name (requires scanning).
 */
function resolveTarget(target: string): { type: "vm" | "service" | "container"; vmId: string; serviceName?: string; containerName?: string } {
  const config = getConfig();
  const { aliasToVm } = buildAliasMapPublic();

  // 1. Is it a VM?
  if (config.vms[target] || aliasToVm[target]) {
    const vmId = aliasToVm[target] ?? target;
    return { type: "vm", vmId };
  }

  // 2. Is it a service?
  if (config.services[target]) {
    const svc = config.services[target];
    return { type: "service", vmId: svc.vm, serviceName: target };
  }

  // 3. Container name — look up in topology (services + VMs have containers arrays)
  // Search services first (maps container → service → VM)
  for (const [svcName, svc] of Object.entries(config.services)) {
    if (svc.containers?.includes(target)) {
      return { type: "container", vmId: svc.vm, serviceName: svcName, containerName: target };
    }
  }
  // Fallback: search VM containers arrays directly
  for (const [vmId, vm] of Object.entries(config.vms)) {
    if (vm.containers?.includes(target)) {
      return { type: "container", vmId, containerName: target };
    }
  }
  // Unknown — return empty vmId (will trigger scanning as last resort)
  return { type: "container", vmId: "", containerName: target };
}

function buildAliasMapPublic(): { aliasToVm: Record<string, string> } {
  const config = getConfig();
  const aliasToVm: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(config.vms)) {
    const alias = vm.ssh_alias ?? VM_SSH_ALIASES_FALLBACK[vmId] ?? vmId;
    aliasToVm[alias] = vmId;
  }
  return { aliasToVm };
}

const VM_SSH_ALIASES_FALLBACK: Record<string, string> = {
  "gcp-E2-f_0": "gcp-proxy",
  "oci-E2-f_0": "oci-mail",
  "oci-E2-f_1": "oci-analytics",
  "oci-A1-f_0": "oci-apps",
};

/**
 * Find which VM a container is running on by scanning all VMs.
 */
function findContainerVm(containerName: string): { vmId: string; status: string } | null {
  const config = getConfig();
  for (const vmId of Object.keys(config.vms)) {
    try {
      const { containers, ok } = listContainers(vmId);
      if (!ok) continue;
      const match = containers.find((c) => c.name === containerName);
      if (match) return { vmId, status: match.status ?? "" };
    } catch { /* skip unreachable VMs */ }
  }
  return null;
}

/**
 * /up/:target — Quick TCP-level check (is the target reachable?)
 * - VM: ssh-keyscan (tier1)
 * - Service: tier1 on its VM + check if any matching container exists
 * - Container: find VM + check docker inspect State.Running
 */
export function checkUp(target: string): UpResult {
  const resolved = resolveTarget(target);
  const start = Date.now();

  if (resolved.type === "vm") {
    const t1 = checkTier1All(resolved.vmId);
    const latencyMs = Date.now() - start;
    const result = t1[0];
    return {
      target,
      type: "vm",
      up: result?.reachable ?? false,
      latencyMs,
      error: result?.error,
    };
  }

  if (resolved.type === "service") {
    // Check VM reachable + service containers running
    const vmId = resolved.vmId;
    if (vmId === "local" || vmId === "all") {
      return { target, type: "service", up: true, latencyMs: 0, details: "local service" };
    }
    const t1 = checkTier1All(vmId);
    const vmUp = t1[0]?.reachable ?? false;
    if (!vmUp) {
      return { target, type: "service", up: false, latencyMs: Date.now() - start, error: "VM unreachable" };
    }
    // Check if containers matching service name are running
    try {
      const { containers, ok } = listContainers(vmId);
      if (!ok) {
        return { target, type: "service", up: false, latencyMs: Date.now() - start, error: "docker ps failed" };
      }
      const matching = containers.filter((c) => c.name?.includes(target));
      const allUp = matching.length > 0 && matching.every((c) => c.status?.toLowerCase().includes("up"));
      return {
        target,
        type: "service",
        up: allUp,
        latencyMs: Date.now() - start,
        details: `${matching.length} container(s): ${matching.map((c) => `${c.name}=${c.status}`).join(", ") || "none found"}`,
      };
    } catch (err) {
      return { target, type: "service", up: false, latencyMs: Date.now() - start, error: String(err) };
    }
  }

  // Container — use topology-resolved VM if available, fallback to scanning
  const containerName = resolved.containerName ?? target;
  const found = resolved.vmId
    ? findContainerOnVm(resolved.vmId, containerName)
    : findContainerVm(containerName);
  if (!found) {
    return { target, type: "container", up: false, latencyMs: Date.now() - start, error: "container not found on any VM" };
  }
  const isUp = found.status.toLowerCase().includes("up");
  return {
    target,
    type: "container",
    up: isUp,
    latencyMs: Date.now() - start,
    details: found.status,
  };
}

/**
 * Check a specific container on a known VM (no scanning).
 */
function findContainerOnVm(vmId: string, containerName: string): { vmId: string; status: string } | null {
  try {
    const { containers, ok } = listContainers(vmId);
    if (!ok) return null;
    const match = containers.find((c) => c.name === containerName);
    if (match) return { vmId, status: match.status ?? "" };
  } catch { /* VM unreachable */ }
  return null;
}

/**
 * /health/:target — Full health check (SSH + docker health status)
 * - VM: tier2 (full SSH auth)
 * - Service: SSH + docker inspect health for all matching containers
 * - Container: SSH + docker inspect health status
 */
export function checkHealth(target: string): HealthResult {
  const resolved = resolveTarget(target);
  const start = Date.now();

  if (resolved.type === "vm") {
    const t2 = checkTier2All(resolved.vmId);
    const latencyMs = Date.now() - start;
    const result = t2[0];
    return {
      target,
      type: "vm",
      up: result?.reachable ?? false,
      healthy: result?.sshOk ?? false,
      latencyMs,
      error: result?.sshError ?? result?.error,
      info: result ? { ip: result.ip, alias: result.alias } : undefined,
    };
  }

  if (resolved.type === "service") {
    const vmId = resolved.vmId;
    if (vmId === "local" || vmId === "all") {
      return { target, type: "service", up: true, healthy: true, latencyMs: 0, details: "local service" };
    }
    try {
      const { containers, ok } = listContainers(vmId);
      if (!ok) {
        return { target, type: "service", up: false, healthy: false, latencyMs: Date.now() - start, error: "docker ps failed" };
      }
      const matching = containers.filter((c) => c.name?.includes(target));
      if (matching.length === 0) {
        return { target, type: "service", up: false, healthy: false, latencyMs: Date.now() - start, error: "no containers found" };
      }
      // Check docker health for each container
      const healthResults = matching.map((c) => {
        const inspectResult = sshExec(vmId, `docker inspect --format '{{.State.Health.Status}}' ${c.name} 2>/dev/null || echo "no-healthcheck"`, 10_000);
        const healthStatus = inspectResult.ok ? inspectResult.stdout.trim() : "unknown";
        return { name: c.name ?? "", status: c.status ?? "", health: healthStatus };
      });
      const allUp = matching.every((c) => c.status?.toLowerCase().includes("up"));
      const allHealthy = healthResults.every((h) => h.health === "healthy" || h.health === "no-healthcheck");
      return {
        target,
        type: "service",
        up: allUp,
        healthy: allUp && allHealthy,
        latencyMs: Date.now() - start,
        status: allHealthy ? "healthy" : healthResults.find((h) => h.health !== "healthy" && h.health !== "no-healthcheck")?.health,
        info: { containers: healthResults } as unknown as Record<string, unknown>,
      };
    } catch (err) {
      return { target, type: "service", up: false, healthy: false, latencyMs: Date.now() - start, error: String(err) };
    }
  }

  // Container — use topology-resolved VM if available, fallback to scanning
  const cName = resolved.containerName ?? target;
  const found = resolved.vmId
    ? findContainerOnVm(resolved.vmId, cName)
    : findContainerVm(cName);
  if (!found) {
    return { target, type: "container", up: false, healthy: false, latencyMs: Date.now() - start, error: "container not found on any VM" };
  }
  const isUp = found.status.toLowerCase().includes("up");
  const inspectResult = sshExec(found.vmId, `docker inspect --format '{{.State.Health.Status}}' ${cName} 2>/dev/null || echo "no-healthcheck"`, 10_000);
  const healthStatus = inspectResult.ok ? inspectResult.stdout.trim() : "unknown";
  return {
    target,
    type: "container",
    up: isUp,
    healthy: isUp && (healthStatus === "healthy" || healthStatus === "no-healthcheck"),
    latencyMs: Date.now() - start,
    status: healthStatus,
    details: found.status,
  };
}

// ── New: Metrics snapshot ────────────────────────────────────────────────

export interface ContainerMetrics {
  name: string;
  cpuPercent: string;
  memUsage: string;
  memPercent: string;
  netIO: string;
  blockIO: string;
  pids: string;
}

export interface VmMetricsSnapshot {
  vm: string;
  alias: string;
  containers: ContainerMetrics[];
  error?: string;
}

export function metricsSnapshot(vmFilter?: string): VmMetricsSnapshot[] {
  const config = getConfig();
  const vmIds = vmFilter ? [resolveVmId(vmFilter)] : Object.keys(config.vms);
  const results: VmMetricsSnapshot[] = [];

  for (const vmId of vmIds) {
    const alias = getVmSshAlias(vmId);
    const result = sshExec(
      vmId,
      `docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' 2>/dev/null`,
      15_000,
    );

    if (!result.ok || !result.stdout.trim()) {
      results.push({ vm: vmId, alias, containers: [], error: result.stderr.trim() || "unreachable" });
      continue;
    }

    const containers: ContainerMetrics[] = result.stdout.trim().split("\n").map((line) => {
      const [name, cpuPercent, memUsage, memPercent, netIO, blockIO, pids] = line.split("\t");
      return {
        name: name ?? "",
        cpuPercent: cpuPercent ?? "",
        memUsage: memUsage ?? "",
        memPercent: memPercent ?? "",
        netIO: netIO ?? "",
        blockIO: blockIO ?? "",
        pids: pids ?? "",
      };
    });

    results.push({ vm: vmId, alias, containers });
  }

  return results;
}
