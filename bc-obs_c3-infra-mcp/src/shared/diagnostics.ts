import { sshExec } from "./ssh.js";
import { getConfig, resolveVmId, getVmSshAlias } from "./config.js";
import { listContainers } from "./docker.js";
import { exec } from "./exec.js";
import type { z } from "zod";
import type { DiagnosticCheckSchema, ProfilingResponseSchema } from "./schemas.js";

type DiagnosticCheck = z.infer<typeof DiagnosticCheckSchema>;
type ProfilingResponse = z.infer<typeof ProfilingResponseSchema>;

function timedCheck(name: string, fn: () => { passed: boolean; details: string }): DiagnosticCheck {
  const start = Date.now();
  try {
    const result = fn();
    return { name, ...result, durationMs: Date.now() - start };
  } catch (err: unknown) {
    return {
      name,
      passed: false,
      details: "",
      error: err instanceof Error ? err.message : String(err),
      durationMs: Date.now() - start,
    };
  }
}

function findContainerVm(containerName: string): string | null {
  const config = getConfig();
  for (const [vmId] of Object.entries(config.vms)) {
    const { containers } = listContainers(vmId, true);
    if (containers.some((c) => c.name === containerName)) {
      return vmId;
    }
  }
  return null;
}

export function profileContainer(containerName: string): ProfilingResponse {
  // Find which VM has this container
  const vmId = findContainerVm(containerName);
  if (!vmId) {
    return {
      container: containerName,
      checks: [{ name: "locate", passed: false, details: "Container not found on any VM" }],
      passed: 0,
      failed: 1,
      total: 1,
    };
  }

  const alias = getVmSshAlias(vmId);
  const config = getConfig();
  const vmConfig = config.vms[vmId];
  const checks: DiagnosticCheck[] = [];

  // Check 1: WireGuard ping
  checks.push(timedCheck("wg_ping", () => {
    const result = exec("ping", ["-c", "1", "-W", "3", vmConfig.ip], { timeout: 5_000 });
    return {
      passed: result.ok,
      details: result.ok ? `Ping to ${vmConfig.ip}: OK` : `Ping to ${vmConfig.ip}: FAILED`,
    };
  }));

  // Check 2: SSH connectivity
  checks.push(timedCheck("ssh_connect", () => {
    const result = sshExec(vmId, "echo ok", 10_000);
    return {
      passed: result.ok,
      details: result.ok ? "SSH session: OK" : `SSH failed: ${result.stderr}`,
    };
  }));

  // Batch checks 3+4: container status + docker network (single SSH call)
  checks.push(timedCheck("container_status", () => {
    const result = sshExec(vmId, [
      `docker inspect --format '{{.State.Status}}|{{.State.Health.Status}}|{{.RestartCount}}|{{.State.OOMKilled}}' ${containerName} 2>/dev/null`,
      `docker network inspect $(docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' ${containerName} 2>/dev/null) --format '{{.Name}}: {{range .Containers}}{{.Name}} {{end}}' 2>/dev/null`,
    ].join(" && echo '===NET===' && "), 10_000);

    if (!result.ok) {
      return { passed: false, details: `Container inspect failed: ${result.stderr}` };
    }

    const parts = result.stdout.split("===NET===");
    const statusLine = (parts[0] ?? "").trim();
    const networkLine = (parts[1] ?? "").trim();

    const [status, health, restarts, oom] = statusLine.split("|");
    const isRunning = status === "running";
    const details = [
      `Status: ${status}`,
      health ? `Health: ${health}` : null,
      `Restarts: ${restarts}`,
      oom === "true" ? "OOM KILLED!" : null,
      networkLine ? `Networks: ${networkLine}` : null,
    ].filter(Boolean).join(", ");

    return { passed: isRunning, details };
  }));

  // Batch checks 5+7: port reachability from host + iptables DNAT (single SSH call)
  checks.push(timedCheck("port_reachability", () => {
    const result = sshExec(vmId, [
      `docker port ${containerName} 2>/dev/null`,
      `sudo nft list ruleset 2>/dev/null | grep -i "${containerName}" | head -5 || echo "(no DNAT rules found)"`,
    ].join(" && echo '===DNAT===' && "), 10_000);

    const parts = result.stdout.split("===DNAT===");
    const ports = (parts[0] ?? "").trim();
    const dnat = (parts[1] ?? "").trim();

    return {
      passed: ports.length > 0,
      details: [
        ports ? `Ports: ${ports}` : "No ports published",
        dnat ? `DNAT: ${dnat}` : "",
      ].filter(Boolean).join("\n"),
    };
  }));

  // Check 6: port reachability via WireGuard
  checks.push(timedCheck("wg_port_probe", () => {
    // Get published ports from container
    const portResult = sshExec(vmId, `docker port ${containerName} 2>/dev/null | head -3`, 5_000);
    if (!portResult.ok || !portResult.stdout.trim()) {
      return { passed: true, details: "No published ports to probe" };
    }

    const portLines = portResult.stdout.trim().split("\n");
    const results: string[] = [];
    for (const line of portLines.slice(0, 3)) {
      const match = line.match(/:(\d+)$/);
      if (match) {
        const port = match[1];
        const probe = exec("bash", ["-c", `timeout 3 bash -c "echo > /dev/tcp/${vmConfig.ip}/${port}" 2>/dev/null`], { timeout: 5_000 });
        results.push(`${vmConfig.ip}:${port} ${probe.ok ? "OPEN" : "CLOSED"}`);
      }
    }

    return {
      passed: results.some((r) => r.includes("OPEN")),
      details: results.join(", ") || "No ports to probe",
    };
  }));

  // Check 7: container resource usage
  checks.push(timedCheck("resources", () => {
    const result = sshExec(vmId, `docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}" ${containerName} 2>/dev/null`, 10_000);
    if (!result.ok) {
      return { passed: true, details: "Stats unavailable" };
    }

    const [cpu, mem, memPct, net, block, pids] = result.stdout.trim().split("|");
    return {
      passed: true,
      details: `CPU: ${cpu}, Mem: ${mem} (${memPct}), Net I/O: ${net}, Block I/O: ${block}, PIDs: ${pids}`,
    };
  }));

  // Check 8: container logs (last 5 lines for errors)
  checks.push(timedCheck("recent_logs", () => {
    const result = sshExec(vmId, `docker logs --tail 5 ${containerName} 2>&1`, 5_000);
    const output = result.stdout.trim();
    const hasErrors = /error|fatal|panic|exception/i.test(output);
    return {
      passed: !hasErrors,
      details: output || "(empty)",
    };
  }));

  const passed = checks.filter((c) => c.passed).length;
  const failed = checks.filter((c) => !c.passed).length;

  return {
    container: containerName,
    vm: alias,
    checks,
    passed,
    failed,
    total: checks.length,
  };
}

export function profileVm(vmNameOrAlias: string): ProfilingResponse[] {
  const vmId = resolveVmId(vmNameOrAlias);
  const { containers } = listContainers(vmId, false);

  return containers.map((c) => profileContainer(c.name));
}

// ── New: Profile by service name ─────────────────────────────────────────

export function profileService(serviceName: string): ProfilingResponse[] {
  const config = getConfig();
  const svc = config.services[serviceName];
  if (!svc) throw new Error(`Unknown service: ${serviceName}`);
  if (svc.vm === "local" || svc.vm === "all") {
    throw new Error(`Cannot profile service with vm=${svc.vm}`);
  }

  const vmId = svc.vm;
  const { containers } = listContainers(vmId, true);
  const matching = containers.filter((c) => c.name.includes(serviceName));

  if (matching.length === 0) {
    return [{
      container: serviceName,
      vm: getVmSshAlias(vmId),
      checks: [{ name: "locate", passed: false, details: `No containers found matching "${serviceName}"` }],
      passed: 0,
      failed: 1,
      total: 1,
    }];
  }

  return matching.map((c) => profileContainer(c.name));
}

// ── New: VM-level diagnostics ────────────────────────────────────────────

export function vmNetwork(vmNameOrAlias: string): { ok: boolean; output: string } {
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null", 10_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function vmTop(vmNameOrAlias: string): { ok: boolean; output: string } {
  const vmId = resolveVmId(vmNameOrAlias);
  const result = sshExec(vmId, "ps aux --sort=-%mem | head -20", 10_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function vmDiskUsage(vmNameOrAlias: string): { ok: boolean; output: string } {
  const vmId = resolveVmId(vmNameOrAlias);
  const config = getConfig();
  const remoteBase = config.remote_base;
  const result = sshExec(vmId, `du -sh ${remoteBase}/* 2>/dev/null | sort -rh | head -30`, 15_000);
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}

export function vmJournal(
  vmNameOrAlias: string,
  since = "1h",
  lines = 100,
): { ok: boolean; output: string } {
  const vmId = resolveVmId(vmNameOrAlias);
  const safeLines = Math.max(1, Math.min(Math.floor(lines), 5000));
  const result = sshExec(
    vmId,
    `journalctl --since "${since} ago" --no-pager -n ${safeLines} 2>/dev/null || echo "(journalctl unavailable)"`,
    15_000,
  );
  return { ok: result.ok, output: (result.stdout + result.stderr).trim() };
}
