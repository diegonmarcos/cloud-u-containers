import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sshExec } from "../utils/ssh.js";
import { getConfig, resolveVmId, getVmSshAlias, getServiceDir } from "../config.js";

const CONTAINER_NAME_RE = /^[a-zA-Z0-9_.-]+$/;

function validateContainerName(name: string): void {
  if (!CONTAINER_NAME_RE.test(name)) {
    throw new Error(`Invalid container name: ${name}`);
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
    "Start, stop, or restart a Docker container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      action: z.enum(["start", "stop", "restart"]).describe("Action to perform"),
    },
    async ({ vm, container, action }) => {
      validateContainerName(container);
      const vmId = resolveVmId(vm);
      const result = sshExec(vmId, `docker ${action} ${container}`);

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
    "Get Docker container logs from a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      container: z.string().describe("Container name"),
      lines: z.number().optional().describe("Number of lines (default: 100)"),
      since: z.string().optional().describe("Show logs since (e.g. '1h', '30m', '2024-01-01')"),
    },
    async ({ vm, container, lines, since }) => {
      validateContainerName(container);
      const vmId = resolveVmId(vm);
      let cmd = `docker logs --tail ${lines ?? 100}`;
      if (since) cmd += ` --since ${since}`;
      cmd += ` ${container}`;

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
    "Rebuild and restart a service on its VM via docker compose",
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
      const remotePath = `${config.remote_base}/${service}`;
      const cmd = `cd ${remotePath} && docker compose down 2>/dev/null; docker compose up -d`;

      const result = sshExec(vmId, cmd, 60_000);
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
