import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const NTFY_BASE = "http://10.0.0.1:8090";
const ntfyToken = () => process.env.NTFY_TOKEN ?? "";

function ntfyHeaders(): Record<string, string> | undefined {
  const token = ntfyToken();
  return token ? { Authorization: `Bearer ${token}` } : undefined;
}

function ntfyGet(path: string): string {
  const result = rawHttpRequest("GET", `${NTFY_BASE}${path}`, undefined, 10_000, ntfyHeaders());
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerNtfyTools(server: McpServer) {
  server.tool(
    "ntfy-health",
    "Check ntfy server health",
    {},
    async () => ({
      content: [{ type: "text" as const, text: ntfyGet("/v1/health") }],
    })
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
      click: z.string().optional().describe("URL to open when notification is clicked"),
      actions: z.string().optional().describe("JSON array of action buttons"),
      attach: z.string().optional().describe("URL of file to attach"),
      delay: z.string().optional().describe("Delivery delay (e.g. '30m', '2h', 'tomorrow 9am')"),
    },
    async ({ topic, message, title, priority, tags, click, actions, attach, delay }) => {
      const payload: Record<string, unknown> = { topic, message };
      if (title) payload.title = title;
      if (priority) payload.priority = priority;
      if (tags) payload.tags = tags;
      if (click) payload.click = click;
      if (attach) payload.attach = attach;
      if (delay) payload.delay = delay;
      if (actions) {
        try { payload.actions = JSON.parse(actions); } catch { payload.actions = actions; }
      }

      const result = rawHttpRequest("POST", NTFY_BASE, JSON.stringify(payload), 10_000, ntfyHeaders());
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    "ntfy-read",
    "Read cached messages from a ntfy topic",
    {
      topic: z.string().describe("Topic name to read messages from"),
      since: z.string().default("24h").describe("Time range: '10m', '1h', '24h', or message ID"),
    },
    async ({ topic, since }) => {
      const result = rawHttpRequest(
        "GET",
        `${NTFY_BASE}/${encodeURIComponent(topic)}/json?poll=1&since=${encodeURIComponent(since)}`,
        undefined, 10_000, ntfyHeaders()
      );
      if (!result.ok) {
        return { content: [{ type: "text" as const, text: JSON.stringify({ error: result.error }, null, 2) }] };
      }
      // ntfy returns newline-delimited JSON
      const messages = result.raw.split("\n").filter(Boolean).map((line) => {
        try { return JSON.parse(line); } catch { return line; }
      });
      return {
        content: [{ type: "text" as const, text: JSON.stringify(messages, null, 2) }],
      };
    }
  );

  server.tool(
    "ntfy-stats",
    "Get ntfy server stats (topics, messages)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: ntfyGet("/v1/stats") }],
    })
  );

  server.tool(
    "ntfy-tier",
    "Get ntfy account tier and usage info",
    {},
    async () => ({
      content: [{ type: "text" as const, text: ntfyGet("/v1/account") }],
    })
  );
}
