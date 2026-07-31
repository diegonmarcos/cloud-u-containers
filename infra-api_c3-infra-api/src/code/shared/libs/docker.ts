import { sshExec } from "./ssh.js";
import { getConfig, resolveVmId, getVmSshAlias, getServiceFolder } from "./config.js";
import { audit } from "./audit.js";
import { validateContainerName, validateSince, validatePathComponent } from "./validators.js";
import type { z } from "zod";
import type { ContainerStatusSchema } from "./schemas.js";

type ContainerStatus = z.infer<typeof ContainerStatusSchema>;

export function listContainers(
  vmNameOrAlias: string,
  includeAll = false,
): { containers: ContainerStatus[]; raw: string; ok: boolean } {
  const vmId = resolveVmId(vmNameOrAlias);
  const fmt = '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}';
  const cmd = includeAll
    ? `docker ps -a --format "${fmt}"`
    : `docker ps --format "${fmt}"`;

  const result = sshExec(vmId, cmd);
  if (!result.ok || !result.stdout.trim()) {
    return { containers: [], raw: result.stdout + result.stderr, ok: result.ok };
  }

  const containers: ContainerStatus[] = result.stdout
    .trim()
    .split("\n")
    .map((line) => {
      const [name, status, image, ports] = line.split("\t");
      return { name: name ?? "", status: status ?? "", image, ports };
    });

  return { containers, raw: result.stdout, ok: true };
}

export function controlContainer(
  vmNameOrAlias: string,
  container: string,
  action: "start" | "stop" | "restart",
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker ${action} ${container}`);
  audit(
    "docker_control",
    `${action} ${container}@${getVmSshAlias(vmId)}`,
    result.ok ? "OK" : `FAILED (exit ${result.exitCode})`,
  );
  return { ok: result.ok, output: `${result.stdout}${result.stderr}` };
}

export function getContainerLogs(
  vmNameOrAlias: string,
  container: string,
  lines = 100,
  since?: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  if (since) validateSince(since);
  const vmId = resolveVmId(vmNameOrAlias);
  const safeTail = Math.max(1, Math.min(Math.floor(lines), 10000));
  let cmd = `docker logs --tail ${safeTail}`;
  if (since) cmd += ` --since ${since}`;
  cmd += ` ${container}`;

  const result = sshExec(vmId, cmd, 15_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function composeUp(
  service: string,
): { ok: boolean; output: string; vm: string } {
  const config = getConfig();
  const svc = config.services[service];
  if (!svc) throw new Error(`Unknown service: ${service}`);
  if (svc.vm === "local" || svc.vm === "all") {
    throw new Error(`Cannot compose for vm=${svc.vm}`);
  }

  const vmId = svc.vm;
  validatePathComponent(service);
  const remotePath = `${config.remote_base}/${service}`;
  const envFlag = '$([ -f .secrets ] && echo "--env-file .secrets")';
  const cmd = `cd ${remotePath} && docker compose down 2>/dev/null; docker compose ${envFlag} up -d`;

  const result = sshExec(vmId, cmd, 60_000);
  const alias = getVmSshAlias(vmId);
  audit("docker_compose_up", `${service}@${alias}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

  return { ok: result.ok, output: `${result.stdout}${result.stderr}`, vm: alias };
}

export function batchContainerStatuses(
  vmNameOrAlias: string,
): ContainerStatus[] {
  const { containers } = listContainers(vmNameOrAlias, true);
  return containers;
}

export function computeServiceStatus(
  vmNameOrAlias: string,
  serviceName: string,
): { running: string[]; stopped: string[]; missing: string[] } {
  const containers = batchContainerStatuses(vmNameOrAlias);
  const serviceContainers = containers.filter((c) =>
    c.name.includes(serviceName),
  );

  const running = serviceContainers
    .filter((c) => c.status.toLowerCase().startsWith("up"))
    .map((c) => c.name);
  const stopped = serviceContainers
    .filter((c) => !c.status.toLowerCase().startsWith("up"))
    .map((c) => c.name);

  return { running, stopped, missing: [] };
}

// ── New: Container Inspection ────────────────────────────────────────────

const SENSITIVE_ENV_RE = /^(.*(?:PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|API_KEY)=).*/i;

export function containerTop(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker top ${container} -eo pid,user,%cpu,%mem,vsz,rss,comm`, 10_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function containerDiff(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker diff ${container}`, 10_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function containerInspectFull(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; data: unknown } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker inspect ${container}`, 10_000);

  if (!result.ok) {
    return { ok: false, data: result.stderr.trim() };
  }

  try {
    const parsed = JSON.parse(result.stdout);
    // Redact sensitive environment variables
    if (Array.isArray(parsed)) {
      for (const item of parsed) {
        const env = item?.Config?.Env;
        if (Array.isArray(env)) {
          item.Config.Env = env.map((e: string) => {
            const match = e.match(SENSITIVE_ENV_RE);
            return match ? `${match[1]}***REDACTED***` : e;
          });
        }
      }
    }
    return { ok: true, data: parsed };
  } catch {
    return { ok: true, data: result.stdout.trim() };
  }
}

export function containerEvents(
  vmNameOrAlias: string,
  container: string,
  since = "1h",
): { ok: boolean; output: string } {
  validateContainerName(container);
  if (since) validateSince(since);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(
    vmId,
    `docker events --filter container=${container} --since ${since} --until now --format '{{.Time}} {{.Action}} {{.Actor.Attributes.name}}' 2>/dev/null | tail -50`,
    15_000,
  );
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() || "(no events)" };
}

export function containerPause(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker pause ${container}`);
  audit("docker_pause", `${container}@${getVmSshAlias(vmId)}`, result.ok ? "OK" : "FAILED");
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function containerUnpause(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker unpause ${container}`);
  audit("docker_unpause", `${container}@${getVmSshAlias(vmId)}`, result.ok ? "OK" : "FAILED");
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function containerExecCmd(
  vmNameOrAlias: string,
  container: string,
  command: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  // Escape single quotes in the command for safe SSH passthrough
  const escaped = command.replace(/'/g, "'\\''");
  const result = sshExec(vmId, `docker exec ${container} sh -c '${escaped}'`, 30_000);
  audit("docker_exec", `${container}@${getVmSshAlias(vmId)}: ${command.slice(0, 80)}`, result.ok ? "OK" : "FAILED");
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

// ── New: Log Utilities ───────────────────────────────────────────────────

export function logsSearch(
  vmNameOrAlias: string,
  container: string,
  pattern: string,
  lines = 1000,
): { ok: boolean; output: string; matchCount: number } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const safeTail = Math.max(1, Math.min(Math.floor(lines), 10000));
  // Escape pattern for grep
  const safePattern = pattern.replace(/['"\\]/g, "\\$&");
  const result = sshExec(
    vmId,
    `docker logs --tail ${safeTail} ${container} 2>&1 | grep -i '${safePattern}' | tail -100`,
    15_000,
  );
  const output = result.stdout.trim();
  const matchCount = output ? output.split("\n").length : 0;
  return { ok: true, output: output || "(no matches)", matchCount };
}

export function logsMulti(
  serviceName: string,
  lines = 50,
): { ok: boolean; output: string } {
  const config = getConfig();
  const svc = config.services[serviceName];
  if (!svc) return { ok: false, output: `Unknown service: ${serviceName}` };
  if (svc.vm === "local" || svc.vm === "all") {
    return { ok: false, output: `Cannot get logs for vm=${svc.vm}` };
  }

  const vmId = svc.vm;
  const alias = getVmSshAlias(vmId);
  const safeTail = Math.max(1, Math.min(Math.floor(lines), 5000));

  // Get all containers matching the service name
  const { containers } = listContainers(vmId, true);
  const matching = containers.filter((c) => c.name.includes(serviceName));

  if (matching.length === 0) {
    return { ok: false, output: `No containers found for ${serviceName} on ${alias}` };
  }

  const parts: string[] = [];
  for (const c of matching) {
    const logResult = sshExec(vmId, `docker logs --tail ${safeTail} ${c.name} 2>&1`, 10_000);
    parts.push(`=== ${c.name} (${c.status}) ===\n${logResult.stdout.trim() || "(empty)"}`);
  }

  return { ok: true, output: parts.join("\n\n") };
}

// ── New: Docker System ───────────────────────────────────────────────────

export function composeUpAll(
  vmNameOrAlias: string,
): { ok: boolean; output: string; results: { service: string; ok: boolean }[] } {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);
  const config = getConfig();

  // List all service dirs on the VM
  const lsResult = sshExec(vmId, `ls -1 ${config.remote_base}/`, 10_000);
  if (!lsResult.ok) {
    return { ok: false, output: `Failed to list services: ${lsResult.stderr}`, results: [] };
  }

  const dirs = lsResult.stdout.trim().split("\n").filter(Boolean);
  const results: { service: string; ok: boolean }[] = [];
  const parts: string[] = [];

  for (const dir of dirs) {
    const envFlag = '$([ -f .secrets ] && echo "--env-file .secrets")';
    const cmd = `cd ${config.remote_base}/${dir} && docker compose ${envFlag} up -d 2>&1`;
    const result = sshExec(vmId, cmd, 60_000);
    const status = result.ok ? "OK" : "FAILED";
    results.push({ service: dir, ok: result.ok });
    parts.push(`${dir}: ${status}`);
    if (!result.ok) parts.push(`  ${result.stderr.trim()}`);
  }

  const allOk = results.every((r) => r.ok);
  audit("compose_up_all", `${alias} (${results.length} services)`, allOk ? "OK" : "PARTIAL");

  return { ok: allOk, output: parts.join("\n"), results };
}

// ── Pull + Up via the deployed engine script ─────────────────────────────
// Wraps /opt/scripts/vm-images-pull-up.sh (home-manager managed, manifest-driven
// serial pull then serial compose-up). Do not reimplement its logic here.

const PULL_UP_CMD = "/opt/scripts/vm-images-pull-up.sh --manifest /opt/scripts/build-vm.json";

function runPullUp(
  vmNameOrAlias: string,
  filter?: string,
): { alias: string; ok: boolean; output: string } {
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);
  const cmd = filter ? `${PULL_UP_CMD} ${filter}` : PULL_UP_CMD;
  const result = sshExec(vmId, cmd, 300_000);
  return { alias, ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function pullUpContainer(
  service: string,
): { ok: boolean; output: string; vm: string } {
  const config = getConfig();
  const svc = config.services[service];
  if (!svc) throw new Error(`Unknown service: ${service}`);
  if (svc.vm === "local" || svc.vm === "all") {
    throw new Error(`Cannot pull/up for vm=${svc.vm}`);
  }
  validatePathComponent(service);

  const { alias, ok, output } = runPullUp(svc.vm, service);
  audit("pull_up_container", `${service}@${alias}`, ok ? "OK" : "FAILED");
  return { ok, output, vm: alias };
}

export function pullUpVmFleet(
  vmNameOrAlias: string,
): { ok: boolean; output: string; vm: string } {
  const { alias, ok, output } = runPullUp(vmNameOrAlias);
  audit("pull_up_vm_fleet", alias, ok ? "OK" : "FAILED");
  return { ok, output, vm: alias };
}

export function pullUpCloudFleet(): {
  ok: boolean;
  results: { vm: string; ok: boolean; output: string }[];
} {
  const config = getConfig();
  const results = Object.keys(config.vms).map((vmId) => {
    const { alias, ok, output } = runPullUp(vmId);
    return { vm: alias, ok, output };
  });
  const allOk = results.every((r) => r.ok);
  audit("pull_up_cloud_fleet", `${results.length} vms`, allOk ? "OK" : "PARTIAL");
  return { ok: allOk, results };
}

export function dockerSystemDf(
  vmNameOrAlias: string,
): { ok: boolean; output: string } {
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, "docker system df -v 2>/dev/null", 15_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}
