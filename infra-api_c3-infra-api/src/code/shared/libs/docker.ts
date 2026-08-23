import { sshExec } from "./ssh.js";
import { getConfig, resolveVmId, getVmSshAlias, getServiceFolder, composeCd } from "./config.js";
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
  const cmd = `${composeCd(remotePath)} && docker compose down 2>/dev/null; docker compose ${envFlag} up -d`;

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
    const cmd = `${composeCd(`${config.remote_base}/${dir}`)} && docker compose ${envFlag} up -d 2>&1`;
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

// sudo is REQUIRED, not defensive. The script ships in the
// nixhm-sudo-<vm> pilot package and needs root twice: it appends to
// /var/log/images-pull-up.log, and it pulls from GHCR using root's stored
// credentials. Run as the login user it logs "GHCR: no token — cleared
// stale creds, using anonymous pull" and then hangs on an anonymous pull of
// a private image until sshExec's 300s timeout fires — the caller sees a
// silent stall, no container, and no log. ops_deploy-pull-up.yaml has always
// invoked it with sudo; this caller was the outlier. Fixed 2026-08-23.
const PULL_UP_CMD = "sudo /opt/scripts/vm-images-pull-up.sh --manifest /opt/scripts/build-vm.json";

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

// ── New: Container update (pull + recreate) ──────────────────────────────

/**
 * Pull the container's current image and recreate it.
 *
 * If the container is managed by docker-compose (has the standard
 * com.docker.compose.project.working_dir / .service labels — the same
 * labels composeUp/composeUpAll rely on implicitly), we recreate via
 * `docker compose pull <service> && docker compose up -d <service>`,
 * which correctly reapplies the original run config (env, mounts, ports).
 * Otherwise we only pull the image and report that a manual recreate
 * is required, rather than guessing at run flags and risking dropping
 * config on a plain `docker run`.
 */
export function updateContainer(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; output: string; recreated: boolean } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const labelsCmd = `docker inspect ${container} --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}|{{ index .Config.Labels "com.docker.compose.service" }}'`;
  const labelsResult = sshExec(vmId, labelsCmd, 10_000);
  const [workingDir, service] = labelsResult.ok
    ? labelsResult.stdout.trim().split("|")
    : ["", ""];

  let result: { ok: boolean; output: string; recreated: boolean };

  if (workingDir && service && workingDir !== "<no value>" && service !== "<no value>") {
    const cmd = `cd ${workingDir} && docker compose pull ${service} && docker compose up -d ${service}`;
    const r = sshExec(vmId, cmd, 120_000);
    result = { ok: r.ok, output: `${r.stdout}${r.stderr}`.trim(), recreated: r.ok };
  } else {
    const imageCmd = `docker inspect ${container} --format '{{ .Config.Image }}'`;
    const imageResult = sshExec(vmId, imageCmd, 10_000);
    const image = imageResult.stdout.trim();
    if (!imageResult.ok || !image) {
      return { ok: false, output: `Could not resolve image for ${container}: ${imageResult.stderr}`, recreated: false };
    }
    const r = sshExec(vmId, `docker pull ${image}`, 120_000);
    result = {
      ok: r.ok,
      output: `${r.stdout}${r.stderr}\n(container is not compose-managed; image pulled but NOT recreated — recreate manually to apply)`.trim(),
      recreated: false,
    };
  }

  audit("container_update", `${container}@${alias}`, result.ok ? (result.recreated ? "OK (recreated)" : "OK (pulled only)") : "FAILED");
  return result;
}

// ── New: Live stats for a single container ────────────────────────────────

export interface ContainerStats {
  name: string;
  cpuPerc: string | null;
  memUsage: string | null;
  memPerc: string | null;
  netIO: string | null;
  blockIO: string | null;
  pids: string | null;
}

export function containerStatsOne(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; stats: ContainerStats | null; error?: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const fmt = "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}";
  const result = sshExec(vmId, `docker stats --no-stream --format '${fmt}' ${container}`, 10_000);
  if (!result.ok || !result.stdout.trim()) {
    return { ok: false, stats: null, error: (result.stderr || "no output").trim() };
  }
  const [name, cpuPerc, memUsage, memPerc, netIO, blockIO, pids] = result.stdout.trim().split("|");
  return {
    ok: true,
    stats: { name: name ?? container, cpuPerc: cpuPerc ?? null, memUsage: memUsage ?? null, memPerc: memPerc ?? null, netIO: netIO ?? null, blockIO: blockIO ?? null, pids: pids ?? null },
  };
}

// ── New: Detailed inspect (env/mounts/ports/digest), secret-redacted ─────

/** Broader than SENSITIVE_ENV_RE above — matches the spec's exact key pattern. */
const SECRET_KEY_RE = /secret|password|token|key|pass|credential/i;

export interface ContainerDetails {
  image: string;
  imageDigest: string | null;
  env: Record<string, string>;
  mounts: Array<{ source: string; destination: string; mode: string }>;
  ports: Record<string, unknown>;
  state: string;
}

export function inspectContainerDetails(
  vmNameOrAlias: string,
  container: string,
): { ok: boolean; details: ContainerDetails | null; error?: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, `docker inspect ${container}`, 10_000);
  if (!result.ok) {
    return { ok: false, details: null, error: result.stderr.trim() };
  }

  try {
    const parsed = JSON.parse(result.stdout) as Array<Record<string, any>>;
    const item = parsed[0];
    if (!item) return { ok: false, details: null, error: "empty inspect output" };

    const rawEnv: string[] = item?.Config?.Env ?? [];
    const env: Record<string, string> = {};
    for (const entry of rawEnv) {
      const idx = entry.indexOf("=");
      if (idx < 0) continue;
      const k = entry.slice(0, idx);
      const v = entry.slice(idx + 1);
      env[k] = SECRET_KEY_RE.test(k) ? "***" : v;
    }

    const mounts = (item?.Mounts ?? []).map((m: Record<string, unknown>) => ({
      source: String(m.Source ?? ""),
      destination: String(m.Destination ?? ""),
      mode: String(m.Mode ?? ""),
    }));

    const imageDigestSource: string[] = item?.RepoDigests ?? [];
    const imageDigest = imageDigestSource[0]?.split("@")[1] ?? null;

    return {
      ok: true,
      details: {
        image: item?.Config?.Image ?? "",
        imageDigest,
        env,
        mounts,
        ports: item?.NetworkSettings?.Ports ?? {},
        state: item?.State?.Status ?? "unknown",
      },
    };
  } catch (err) {
    return { ok: false, details: null, error: err instanceof Error ? err.message : String(err) };
  }
}

// ── New: Image update check (local digest vs upstream registry digest) ───

export interface ImageUpdateStatus {
  service: string;
  vm: string;
  container: string;
  image: string;
  localDigest: string | null;
  remoteDigest: string | null;
  updateAvailable: boolean | null; // null = could not be determined
  error?: string;
}

/**
 * Compares each running container's local image digest against the
 * upstream registry digest via `docker manifest inspect` (no image is
 * pulled/modified). Requires the Docker CLI's manifest command to be
 * available on the VM; when it isn't (or the registry call fails) this
 * degrades to updateAvailable: null rather than guessing.
 */
export function checkImageUpdate(
  vmNameOrAlias: string,
  container: string,
): ImageUpdateStatus {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const imageResult = sshExec(vmId, `docker inspect ${container} --format '{{ .Config.Image }}'`, 10_000);
  const image = imageResult.stdout.trim();
  if (!imageResult.ok || !image) {
    return { service: container, vm: alias, container, image: "", localDigest: null, remoteDigest: null, updateAvailable: null, error: "could not resolve image" };
  }

  const digestResult = sshExec(vmId, `docker inspect ${container} --format '{{ index .Image }}'`, 10_000);
  const localDigest = digestResult.ok ? digestResult.stdout.trim() : null;

  const manifestResult = sshExec(vmId, `docker manifest inspect ${image} 2>/dev/null | sha256sum | cut -d' ' -f1`, 20_000);
  const remoteDigest = manifestResult.ok && manifestResult.stdout.trim() ? manifestResult.stdout.trim() : null;

  if (!remoteDigest || !localDigest) {
    return { service: container, vm: alias, container, image, localDigest, remoteDigest, updateAvailable: null, error: "manifest inspect unavailable" };
  }

  return { service: container, vm: alias, container, image, localDigest, remoteDigest, updateAvailable: localDigest !== remoteDigest };
}

// ── New: Allowlisted in-container exec (deny-by-default, no shell interpolation) ─

/**
 * Fixed allowlist mapping a command NAME (from the request body) to a fixed,
 * hardcoded docker argv array. The container name is the only variable part
 * (already passed through validateContainerName), and it is placed as a
 * single ssh/exec argument — never string-concatenated into a shell command
 * built from request-supplied text. Anything not in this map is rejected.
 */
export const EXEC_COMMAND_ALLOWLIST: Record<string, (container: string) => string[]> = {
  restart: (c) => ["restart", c],
  stop: (c) => ["stop", c],
  start: (c) => ["start", c],
  "logs-tail": (c) => ["logs", "--tail", "200", c],
  top: (c) => ["top", c, "-eo", "pid,user,%cpu,%mem,comm"],
  "stats-snapshot": (c) => ["stats", "--no-stream", c],
};

export function runAllowlistedExecCommand(
  vmNameOrAlias: string,
  container: string,
  commandName: string,
): { ok: boolean; output: string } {
  validateContainerName(container);
  const vmId = resolveVmId(vmNameOrAlias);
  const alias = getVmSshAlias(vmId);

  const build = EXEC_COMMAND_ALLOWLIST[commandName];
  if (!build) {
    throw Object.assign(new Error(`Command not allowed: ${commandName}. Allowed: ${Object.keys(EXEC_COMMAND_ALLOWLIST).join(", ")}`), { statusCode: 400 });
  }

  const args = build(container);
  const result = sshExec(vmId, `docker ${args.join(" ")}`, 20_000);
  audit("container_exec_allowlisted", `${commandName} ${container}@${alias}`, result.ok ? "OK" : "FAILED");
  return { ok: result.ok, output: `${result.stdout}${result.stderr}`.trim() };
}
