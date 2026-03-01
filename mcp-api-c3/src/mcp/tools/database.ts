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
      return jsonText(`Health history: ${vm}`, getHealthHistory(vm, limit));
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
      return jsonText(`Uptime report: ${vm}`, getUptimeReport(vm, days));
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
      return jsonText("Audit log", getAuditLog(tool, target, limit));
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
      return jsonText(`Deploy history${service ? `: ${service}` : ""}`, getDeployHistory(service, limit));
    }
  );

  server.tool(
    "db_alert_state",
    "Get current alert state (which alerts have been sent, when)",
    { key: z.string().describe("Alert key (e.g. 'vm_down:oci-apps')") },
    async ({ key }) => {
      return jsonText(`Alert state: ${key}`, getAlertState(key));
    }
  );

  server.tool(
    "db_alert_update",
    "Update alert state (mark alert as sent/resolved)",
    {
      key: z.string().describe("Alert key"),
      sent: z.boolean().describe("Alert sent?"),
    },
    async ({ key, sent }) => {
      updateAlertState(key, sent);
      return { content: [{ type: "text", text: `Alert state updated: ${key} → sent=${sent}` }] };
    }
  );

  server.tool(
    "db_prune",
    "Remove old records from SQLite database (keeps last N days)",
    { days: z.number().optional().describe("Keep last N days (default: 30)") },
    async ({ days }) => {
      const count = pruneOldRecords(days);
      return { content: [{ type: "text", text: `Pruned ${count} old records` }] };
    }
  );
}
