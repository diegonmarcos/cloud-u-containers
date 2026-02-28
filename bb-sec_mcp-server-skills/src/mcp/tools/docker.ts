import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sshExec } from "../../shared/ssh.js";
import { getConfig, resolveVmId, getVmSshAlias, getServiceDir } from "../../shared/config.js";
import { audit } from "../../shared/audit.js";

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

export function registerDockerTools(server: McpServer) {
  server.tool(
    "docker_ps",
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
      return {
        content: [
          {
            type: "text",
            text: `Containers on ${getVmSshAlias(vmId)} (${vmId}):\n\n${result.stdout || "No containers found"}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "docker_control",
    "Start/stop/restart a container via SSH. Use for debugging or when Rust API is down. Prefer container_start/stop/restart for normal operations.",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      action: z.enum(["start", "stop", "restart"]).describe("Action to perform"),
    },
    async ({ vm, container, action }) => {
      validateContainerName(container);
      const vmId = resolveVmId(vm);
      const result = sshExec(vmId, `docker ${action} ${container}`);
      audit("docker_control", `${action} ${container}@${getVmSshAlias(vmId)}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

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
    "docker_logs",
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

      // 15s: log retrieval is fast, but SSH connect can take a few seconds on cold VMs
      const result = sshExec(vmId, cmd, 15_000);
      // Docker logs go to both stdout and stderr
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
    "docker_compose_up",
    "Recreate all containers for a service from its compose file on the VM. Does NOT rebuild images — use build_ship for full pipeline.",
    {
      service: z.string().describe("Service name from config.json"),
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
      const cmd = `cd ${remotePath} && docker compose down 2>/dev/null; docker compose up -d`;

      // 60s: compose pull + recreate can take up to a minute on slow VMs
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
}
