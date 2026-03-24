import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const NTFY_BASE = "http://10.0.0.1:8090";

export function registerNtfyTools(server: McpServer) {
  server.tool(
    "ntfy-health",
    "Check ntfy server health",
    {},
    async () => {
      const result = rawHttpRequest("GET", `${NTFY_BASE}/v1/health`);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    "ntfy-publish",
    "Publish a push notification via ntfy",
    {
      topic: z.string().describe("Topic name"),
      message: z.string().describe("Notification message"),
      title: z.string().optional().describe("Notification title"),
      priority: z.number().min(1).max(5).optional().describe("Priority 1-5"),
      tags: z.array(z.string()).optional().describe("Tags/emojis"),
    },
    async ({ topic, message, title, priority, tags }) => {
      const payload: Record<string, unknown> = { topic, message };
      if (title) payload.title = title;
      if (priority) payload.priority = priority;
      if (tags) payload.tags = tags;

      const result = rawHttpRequest("POST", NTFY_BASE, JSON.stringify(payload));
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );
}
