import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  sendNotification,
  alertHealthDown,
  alertHealthRecovered,
  alertCertExpiring,
  alertDiskFull,
} from "../../shared/notify.js";

export function registerNotifyTools(server: McpServer) {
  server.tool(
    "notify_send",
    "Send a push notification via ntfy.sh",
    {
      title: z.string().describe("Notification title"),
      message: z.string().describe("Notification message"),
      priority: z.enum(["min", "low", "default", "high", "urgent"]).optional().describe("Priority level (default: default)"),
      tags: z.array(z.string()).optional().describe("Tags (e.g. ['warning', 'cloud'])"),
    },
    async ({ title, message, priority, tags }) => {
      const result = sendNotification({ title, message, priority, tags });
      return {
        content: [{ type: "text", text: result.ok ? "Notification sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_health_down",
    "Send alert for a VM/service going down",
    {
      target: z.string().describe("VM or service name"),
      details: z.string().optional().describe("Additional details"),
    },
    async ({ target, details }) => {
      const result = alertHealthDown(target, details);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_health_recovered",
    "Send alert for a VM/service recovery",
    {
      target: z.string().describe("VM or service name"),
      downtime: z.string().optional().describe("Downtime duration (e.g. '2h 15m')"),
    },
    async ({ target, downtime }) => {
      const result = alertHealthRecovered(target, downtime);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_cert_expiring",
    "Send alert for expiring TLS certificate",
    {
      domain: z.string().describe("Domain with expiring cert"),
      daysRemaining: z.number().describe("Days until expiration"),
    },
    async ({ domain, daysRemaining }) => {
      const result = alertCertExpiring(domain, daysRemaining);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_disk_full",
    "Send alert for disk space warning",
    {
      vm: z.string().describe("VM ID or alias"),
      percent: z.number().describe("Disk usage percentage"),
      path: z.string().optional().describe("Mount path (default: /)"),
    },
    async ({ vm, percent, path }) => {
      const result = alertDiskFull(vm, percent, path);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );
}
