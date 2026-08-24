// ── devops.docker/ssh/vm/container/service.* + obs.debug.docker_logs* ──
// SSH, Docker ops, VM/container/service lifecycle, container log tools

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sshExec, checkVmReachable } from "../../shared/libs/ssh.js";
import { getConfig, resolveVmId, getVmSshAlias, getServiceDir, composeCd } from "../../shared/libs/config.js";
import { audit } from "../../shared/libs/audit.js";
import {
  containerTop,
  containerDiff,
  containerInspectFull,
  containerEvents,
  containerPause,
  containerUnpause,
  containerExecCmd,
  logsSearch,
  logsMulti,
  dockerSystemDf,
  composeUpAll,
  pullUpContainer,
  pullUpVmFleet,
  pullUpCloudFleet,
} from "../../shared/libs/docker.js";
import {
  vmStart,
  vmStop,
  vmReset,
  vmSerialConsole,
  vmDrain,
  containerStart,
  containerStop,
  containerRestart,
  serviceStart,
  serviceStop,
  serviceRestart,
} from "../../shared/libs/control.js";

// ── Validation helpers ──

const SAFE_NAME_RE = /^[a-zA-Z0-9_.-]+$/;
const SAFE_SINCE_RE = /^\d+[smhd]$|^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$/;

function validateContainerName(name: string): void {
  if (!SAFE_NAME_RE.test(name)) {
    throw new Error(`Invalid container name: ${name}`);
  }
}

function validateSince(since: string): void {
  if (!SAFE_SINCE_RE.test(since)) {
    throw new Error(`Invalid since format: ${since}. Expected: '1h', '30m', '2d', or '2024-01-01'`);
  }
}

function validatePath(path: string): void {
  if (!SAFE_NAME_RE.test(path)) {
    throw new Error(`Invalid path component: ${path}`);
  }
}

function formatControl(result: { ok: boolean; message: string }) {
  return {
    content: [{ type: "text" as const, text: result.message }],
    isError: !result.ok,
  };
}

export function registerOperationsTools(server: McpServer) {
  // ── SSH (1 tool) ──

  server.tool(
    "devops.ssh.check",
    "Test if a VM is reachable via SSH, optionally with system info",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      detailed: z.boolean().optional().describe("Include system info (uptime, memory, disk)"),
    },
    async ({ vm, detailed }) => {
      const vmId = resolveVmId(vm);
      const alias = getVmSshAlias(vmId);
      const config = getConfig();
      const vmConfig = config.vms[vmId];

      const ping = checkVmReachable(vmId);
      if (!ping.ok) {
        return {
          content: [
            {
              type: "text",
              text: `${alias} (${vmId}) @ ${vmConfig.ip}: UNREACHABLE\n${ping.stderr}`,
            },
          ],
          isError: true,
        };
      }

      if (!detailed) {
        return {
          content: [
            { type: "text", text: `${alias} (${vmId}) @ ${vmConfig.ip}: REACHABLE` },
          ],
        };
      }

      const info = sshExec(
        vmId,
        'echo "=== Uptime ===" && uptime && echo "=== Memory ===" && free -h && echo "=== Disk ===" && df -h / && echo "=== Docker ===" && docker ps --format "table {{.Names}}\\t{{.Status}}" 2>/dev/null || echo "Docker not available"',
        15_000
      );

      const header = `${alias} (${vmId}) @ ${vmConfig.ip}: REACHABLE`;
      if (!info.ok) {
        return {
          content: [
            {
              type: "text",
              text: `${header}\n\n(SSH exec failed for detailed info — exit ${info.exitCode})${info.stderr ? `\n${info.stderr}` : ""}`,
            },
          ],
        };
      }

      return {
        content: [
          {
            type: "text",
            text: `${header}\n\n${info.stdout}`,
          },
        ],
      };
    }
  );

  // ── Docker (14 tools, from docker.ts) ──

  server.tool(
    "devops.docker.ps",
    "List Docker containers on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      all: z.boolean().optional().describe("Include stopped containers"),
    },
    async ({ vm, all }) => {
      const vmId = resolveVmId(vm);
      const cmd = all
        ? 'docker ps -a --format "table {{.Names}}\\t{{.Status}}\\t{{.Image}}\\t{{.Ports}}"'
        : 'docker ps --format "table {{.Names}}\\t{{.Status}}\\t{{.Image}}\\t{{.Ports}}"';

      const result = sshExec(vmId, cmd);
      const body = result.ok
        ? (result.stdout || "No containers found")
        : `SSH FAILED (exit ${result.exitCode}): ${result.stderr.trim() || result.stdout.trim() || "no output"}`;
      return {
        content: [
          {
            type: "text",
            text: `Containers on ${getVmSshAlias(vmId)} (${vmId}):\n\n${body}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.control",
    "Start/stop/restart a container via SSH. Use for debugging or when C3 API is down. Prefer container_start/stop/restart for normal operations.",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      action: z.enum(["start", "stop", "restart"]).describe("Action to perform"),
    },
    async ({ vm, container, action }) => {
      validateContainerName(container);
      const vmId = resolveVmId(vm);
      const result = sshExec(vmId, `docker ${action} ${container}`);
      audit("devops.docker.control", `${action} ${container}@${getVmSshAlias(vmId)}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [
          {
            type: "text",
            text: `docker ${action} ${container} on ${getVmSshAlias(vmId)}: ${result.ok ? "OK" : "FAILED"}\n${result.stdout}${result.stderr}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "obs.debug.docker_logs",
    "Get Docker container logs. since format: '1h', '30m', '2024-01-01'",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      lines: z.number().optional().describe("Number of lines (default: 100)"),
      since: z.string().optional().describe("Show logs since (e.g. '1h', '30m', '2024-01-01')"),
    },
    async ({ vm, container, lines, since }) => {
      validateContainerName(container);
      if (since) validateSince(since);
      const vmId = resolveVmId(vm);
      const safeTail = Math.max(1, Math.min(Math.floor(lines ?? 100), 10000));
      let cmd = `docker logs --tail ${safeTail}`;
      if (since) cmd += ` --since ${since}`;
      cmd += ` ${container}`;

      const result = sshExec(vmId, cmd, 15_000);
      const output = (result.stdout + result.stderr).trim();

      return {
        content: [
          {
            type: "text",
            text: `Logs for ${container} on ${getVmSshAlias(vmId)}:\n\n${output || "(empty)"}`,
          },
        ],
      };
    }
  );

  server.tool(
    "devops.docker.compose_up",
    "Recreate all containers for a service from its compose file on the VM. Does NOT rebuild images — use build_ship for full pipeline.",
    {
      service: z.string().describe("Service name (from build-cloud-infra-mcp.json services map)"),
    },
    async ({ service }) => {
      const config = getConfig();
      const svc = config.services[service];
      if (!svc) {
        return { content: [{ type: "text", text: `Unknown service: ${service}` }], isError: true };
      }
      if (svc.vm === "local" || svc.vm === "all") {
        return {
          content: [{ type: "text", text: `Cannot compose for vm=${svc.vm}` }],
          isError: true,
        };
      }

      const vmId = svc.vm;
      validatePath(service);
      const remotePath = `${config.remote_base}/${service}`;
      const cmd = `${composeCd(remotePath)} && docker compose down 2>/dev/null; docker compose up -d`;

      const result = sshExec(vmId, cmd, 60_000);
      audit("docker_compose_up", `${service}@${getVmSshAlias(vmId)}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);
      return {
        content: [
          {
            type: "text",
            text: `docker compose up ${service} on ${getVmSshAlias(vmId)}:\n${result.ok ? "SUCCESS" : "FAILED"}\n\n${result.stdout}${result.stderr}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.compose_up_scoped",
    "Serial pull+up via the deployed engine (/opt/scripts/vm-images-pull-up.sh, manifest-driven). scope=container needs `target`=service name; scope=vm_fleet needs `target`=VM id/alias; scope=cloud_fleet runs every VM.",
    {
      scope: z.enum(["container", "vm_fleet", "cloud_fleet"]).describe("Blast radius: single service, one VM's fleet, or every VM"),
      target: z.string().optional().describe("Service name (scope=container) or VM id/alias (scope=vm_fleet). Unused for cloud_fleet."),
    },
    async ({ scope, target }) => {
      if (scope === "container") {
        if (!target) return { content: [{ type: "text", text: "target (service name) required for scope=container" }], isError: true };
        const r = pullUpContainer(target);
        return {
          content: [{ type: "text", text: `pull+up ${target} on ${r.vm}:\n${r.ok ? "SUCCESS" : "FAILED"}\n\n${r.output}` }],
          isError: !r.ok,
        };
      }
      if (scope === "vm_fleet") {
        if (!target) return { content: [{ type: "text", text: "target (VM id/alias) required for scope=vm_fleet" }], isError: true };
        const r = pullUpVmFleet(target);
        return {
          content: [{ type: "text", text: `pull+up fleet on ${r.vm}:\n${r.ok ? "SUCCESS" : "FAILED"}\n\n${r.output}` }],
          isError: !r.ok,
        };
      }
      const r = pullUpCloudFleet();
      const text = r.results.map((v) => `=== ${v.vm}: ${v.ok ? "OK" : "FAILED"} ===\n${v.output}`).join("\n\n");
      return {
        content: [{ type: "text", text: `pull+up cloud fleet (${r.results.length} vms):\n${r.ok ? "ALL OK" : "PARTIAL FAILURE"}\n\n${text}` }],
        isError: !r.ok,
      };
    }
  );

  server.tool(
    "devops.docker.compose_up_all",
    "Start all services on a VM by running docker compose up -d in each /opt/containers/* directory",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => {
      const result = composeUpAll(vm);
      return {
        content: [
          {
            type: "text",
            text: `compose up all on ${vm}:\n${result.ok ? "ALL OK" : "PARTIAL FAILURE"}\n\n${result.output}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.top",
    "Show running processes inside a container",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
    },
    async ({ vm, container }) => {
      validateContainerName(container);
      const result = containerTop(vm, container);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.diff",
    "Show filesystem changes in a container since it started",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
    },
    async ({ vm, container }) => {
      validateContainerName(container);
      const result = containerDiff(vm, container);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.inspect",
    "Get full container configuration (env vars redacted)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
    },
    async ({ vm, container }) => {
      validateContainerName(container);
      const result = containerInspectFull(vm, container);
      return {
        content: [{ type: "text", text: result.ok ? JSON.stringify(result.data, null, 2) : `Error: ${String(result.data)}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.events",
    "Stream recent Docker events for a container (last 100 events)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      since: z.string().optional().describe("Show events since (e.g. '1h', '30m')"),
    },
    async ({ vm, container, since }) => {
      validateContainerName(container);
      if (since) validateSince(since);
      const result = containerEvents(vm, container, since);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.pause",
    "Pause a running container (freeze all processes)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
    },
    async ({ vm, container }) => {
      validateContainerName(container);
      const result = containerPause(vm, container);
      return {
        content: [{ type: "text", text: result.output }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.unpause",
    "Unpause a paused container (resume all processes)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
    },
    async ({ vm, container }) => {
      validateContainerName(container);
      const result = containerUnpause(vm, container);
      return {
        content: [{ type: "text", text: result.output }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.exec",
    "Execute a command inside a running container",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      command: z.string().describe("Command to execute (e.g. 'ls -la /app')"),
    },
    async ({ vm, container, command }) => {
      validateContainerName(container);
      const result = containerExecCmd(vm, container, command);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "obs.debug.docker_logs_search",
    "Search container logs for a pattern (grep)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      pattern: z.string().describe("Search pattern (plain text or regex)"),
      lines: z.number().optional().describe("Max log lines to search (default: 1000)"),
    },
    async ({ vm, container, pattern, lines }) => {
      validateContainerName(container);
      const result = logsSearch(vm, container, pattern, lines);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "obs.debug.docker_logs_multi",
    "Get logs from all containers for a service",
    {
      service: z.string().describe("Service name (from build-cloud-infra-mcp.json services map)"),
      lines: z.number().optional().describe("Lines per container (default: 50)"),
    },
    async ({ service, lines }) => {
      const result = logsMulti(service, lines);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.docker.system_df",
    "Show Docker disk usage (images, containers, volumes)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => {
      const result = dockerSystemDf(vm);
      return {
        content: [{ type: "text", text: result.ok ? result.output : `Error: ${result.output}` }],
        isError: !result.ok,
      };
    }
  );

  // ── VM Control (4 tools, from control.ts) ──

  server.tool(
    "devops.vm.start",
    "Start a VM via the C3 API (handles OCI/GCP abstraction)",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmStart(vm)),
  );

  server.tool(
    "devops.vm.stop",
    "Stop a VM gracefully via the C3 API",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmStop(vm)),
  );

  server.tool(
    "devops.vm.reset",
    "Reset/force-restart a VM via the C3 API",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmReset(vm)),
  );

  // Reads the provider's serial console. This is the ONLY VM tool that works
  // on a completely wedged box: it goes to the cloud control plane, not
  // through SSH or the mesh. Added 2026-08-12 after gcp-proxy hung during a
  // deploy and there was no way to tell an OOM from a panic from a slow boot —
  // every other diagnostic routed through the fleet that had just gone down.
  server.tool(
    "devops.vm.console",
    "Read a VM's serial console output from the cloud control plane. Works when the VM is wedged and SSH/WireGuard are dead — use this to find out WHY a VM died (OOM, kernel panic, boot failure).",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      lines: z.number().int().min(1).max(5000).optional()
        .describe("Tail this many lines (default 200)"),
    },
    async ({ vm, lines }) => formatControl(vmSerialConsole(vm, lines ?? 200)),
  );

  server.tool(
    "devops.vm.drain",
    "Gracefully stop all containers on a VM before maintenance",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmDrain(vm)),
  );

  // ── Container Control (3 tools, from control.ts) ──

  server.tool(
    "devops.container.start",
    "Start a container via the C3 API (preferred — handles VM auto-wake and validation).",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => formatControl(containerStart(vm, name)),
  );

  server.tool(
    "devops.container.stop",
    "Stop a container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => formatControl(containerStop(vm, name)),
  );

  server.tool(
    "devops.container.restart",
    "Restart a container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => formatControl(containerRestart(vm, name)),
  );

  // ── Service Control (3 tools, from control.ts) ──

  server.tool(
    "devops.service.start",
    "Start all containers for a service on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => formatControl(serviceStart(vm, service)),
  );

  server.tool(
    "devops.service.stop",
    "Stop all containers for a service on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => formatControl(serviceStop(vm, service)),
  );

  server.tool(
    "devops.service.restart",
    "Restart all containers for a service (compose down + up)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => formatControl(serviceRestart(vm, service)),
  );
}
