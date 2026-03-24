import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

// Two Rig agent instances on oci-apps (10.0.0.6)
const RIG_HEAVY = "http://10.0.0.6:8090";  // DeepSeek R1 14B Q8
const RIG_LIGHT = "http://10.0.0.6:8091";  // Qwen 1.5B Q4

function rigApi(method: string, base: string, path: string, body?: string): string {
  const result = rawHttpRequest(method, `${base}${path}`, body, 30_000);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerRigTools(server: McpServer) {
  server.tool(
    "rig-status",
    "Get Rig agent status, model info, and task counts",
    {
      instance: z.enum(["heavy", "light"]).default("heavy").describe("Agent instance: heavy (14B) or light (1.5B)"),
    },
    async ({ instance }) => ({
      content: [{ type: "text" as const, text: rigApi("GET", instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/api/status") }],
    })
  );

  server.tool(
    "rig-health",
    "Check Rig agent health",
    {
      instance: z.enum(["heavy", "light"]).default("heavy").describe("Agent instance"),
    },
    async ({ instance }) => ({
      content: [{ type: "text" as const, text: rigApi("GET", instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/health") }],
    })
  );

  server.tool(
    "rig-run",
    "Start an agent task (async — returns immediately, check tasks for result)",
    {
      task: z.string().describe("Task description / prompt for the agent"),
      max_turns: z.number().default(15).describe("Max reasoning turns (default 15)"),
      instance: z.enum(["heavy", "light"]).default("heavy").describe("Agent instance: heavy (14B) or light (1.5B)"),
    },
    async ({ task, max_turns, instance }) => ({
      content: [{ type: "text" as const, text: rigApi("POST", instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/agent/run", JSON.stringify({ task, max_turns })) }],
    })
  );

  server.tool(
    "rig-tasks",
    "List all agent tasks (running, completed, failed)",
    {
      instance: z.enum(["heavy", "light"]).default("heavy").describe("Agent instance"),
    },
    async ({ instance }) => ({
      content: [{ type: "text" as const, text: rigApi("GET", instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/agent/tasks") }],
    })
  );

  server.tool(
    "rig-task_detail",
    "Get task detail including steps trace and result",
    {
      id: z.string().describe("Task UUID"),
      instance: z.enum(["heavy", "light"]).default("heavy").describe("Agent instance"),
    },
    async ({ id, instance }) => ({
      content: [{ type: "text" as const, text: rigApi("GET", instance === "light" ? RIG_LIGHT : RIG_HEAVY, `/agent/tasks/${encodeURIComponent(id)}`) }],
    })
  );
}
