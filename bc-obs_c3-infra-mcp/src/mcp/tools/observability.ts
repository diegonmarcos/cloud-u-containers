// ── Observability Exec — "What to do about it" (8 tools) ──
// Notifications, alerts, DB mutations

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  sendNotification,
  alertHealthDown,
  alertHealthRecovered,
  alertCertExpiring,
  alertDiskFull,
} from "../../shared/libs/notify.js";
import {
  getAlertState,
  updateAlertState,
  pruneOldRecords,
} from "../../shared/libs/db.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

export function registerObservabilityExecTools(server: McpServer) {
  // ── Notifications (5 tools) ──

  server.tool(
    "obs.notify.send",
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
    "obs.notify.health_down",
    "Send alert for a VM/service going down",
    {
      target: z.string().describe("VM or service name"),
      details: z.string().optional().describe("Additional details"),
    },
    async ({ target, details }) => {
      const result = alertHealthDown(target, details ?? "");
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${(result as any).error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "obs.notify.health_recovered",
    "Send alert for a VM/service recovery",
    {
      target: z.string().describe("VM or service name"),
    },
    async ({ target }) => {
      const result = alertHealthRecovered(target);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "obs.notify.cert_expiring",
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
    "obs.notify.disk_full",
    "Send alert for disk space warning",
    {
      vm: z.string().describe("VM ID or alias"),
      percent: z.string().describe("Disk usage percentage"),
    },
    async ({ vm, percent }) => {
      const result = alertDiskFull(vm, percent);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  // ── Database Exec (3 tools) ──

  server.tool(
    "obs.db.alert_state",
    "Get current alert state for a VM",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      return jsonText(`Alert state: ${vm}`, getAlertState(vm));
    }
  );

  server.tool(
    "obs.db.alert_update",
    "Update alert state for a VM",
    {
      vm: z.string().describe("VM ID or alias"),
      status: z.string().describe("Current status (e.g. 'up', 'down')"),
      notified: z.boolean().describe("Has notification been sent?"),
    },
    async ({ vm, status, notified }) => {
      updateAlertState(vm, status, notified);
      return { content: [{ type: "text", text: `Alert state updated: ${vm} → ${status} (notified=${notified})` }] };
    }
  );

  server.tool(
    "obs.db.prune",
    "Remove old records from SQLite database (keeps last N days)",
    { days: z.number().optional().describe("Keep last N days (default: 30)") },
    async ({ days }) => {
      const result = pruneOldRecords(days);
      return { content: [{ type: "text", text: `Pruned ${result.healthDeleted + result.auditDeleted + result.deployDeleted} old records (health: ${result.healthDeleted}, audit: ${result.auditDeleted}, deploy: ${result.deployDeleted})` }] };
    }
  );
}
