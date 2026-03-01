import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  getHealthHistory,
  getUptimeReport,
  getAuditLog,
  getDeployHistory,
  getAlertState,
  updateAlertState,
  pruneOldRecords,
} from "../../shared/db.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

export function registerDatabaseTools(server: McpServer) {
  server.tool(
    "db_health_history",
    "Get health check history for a VM (last N checks from SQLite)",
    {
      vm: z.string().describe("VM ID or alias"),
      limit: z.number().optional().describe("Max records (default: 100)"),
    },
    async ({ vm, limit }) => {
      return jsonText(`Health history: ${vm}`, getHealthHistory({ vm, limit }));
    }
  );

  server.tool(
    "db_uptime_report",
    "Get uptime statistics for a VM over a time period",
    {
      vm: z.string().describe("VM ID or alias"),
      days: z.number().optional().describe("Days back (default: 7)"),
    },
    async ({ vm, days }) => {
      const hours = days ? days * 24 : 24 * 7; // Convert days to hours
      return jsonText(`Uptime report: ${vm}`, getUptimeReport(vm, hours));
    }
  );

  server.tool(
    "db_audit_log",
    "Get audit log entries (all mutating operations)",
    {
      tool: z.string().optional().describe("Filter by tool name"),
      target: z.string().optional().describe("Filter by target"),
      limit: z.number().optional().describe("Max records (default: 100)"),
    },
    async ({ tool, target, limit }) => {
      return jsonText("Audit log", getAuditLog({ tool, limit }));
    }
  );

  server.tool(
    "db_deploy_history",
    "Get deployment history for a service",
    {
      service: z.string().optional().describe("Service name (omit for all)"),
      limit: z.number().optional().describe("Max records (default: 50)"),
    },
    async ({ service, limit }) => {
      return jsonText(`Deploy history${service ? `: ${service}` : ""}`, getDeployHistory({ service, limit }));
    }
  );

  server.tool(
    "db_alert_state",
    "Get current alert state for a VM",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      return jsonText(`Alert state: ${vm}`, getAlertState(vm));
    }
  );

  server.tool(
    "db_alert_update",
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
    "db_prune",
    "Remove old records from SQLite database (keeps last N days)",
    { days: z.number().optional().describe("Keep last N days (default: 30)") },
    async ({ days }) => {
      const result = pruneOldRecords(days);
      return { content: [{ type: "text", text: `Pruned ${result.healthDeleted + result.auditDeleted + result.deployDeleted} old records (health: ${result.healthDeleted}, audit: ${result.auditDeleted}, deploy: ${result.deployDeleted})` }] };
    }
  );
}
