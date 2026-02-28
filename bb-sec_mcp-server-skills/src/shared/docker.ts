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
  const cmd = `cd ${remotePath} && docker compose down 2>/dev/null; docker compose up -d`;

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
