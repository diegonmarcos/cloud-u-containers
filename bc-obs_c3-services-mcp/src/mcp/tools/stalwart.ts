import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec } from "../../shared/exec.js";

const STALWART_BASE = "https://10.0.0.3:8443";

function stalwartApi(method: string, path: string, body?: string): string {
  const user = process.env.STALWART_ADMIN_USER ?? "admin@diegonmarcos.com";
  const pass = process.env.STALWART_ADMIN_PASSWORD ?? "";
  const auth = Buffer.from(`${user}:${pass}`).toString("base64");
  const url = `${STALWART_BASE}/api${path}`;
  const args = [
    "-s", "-S", "-k",  // -k: skip TLS verify (WG IP != cert SAN)
    "-X", method,
    "-H", "Content-Type: application/json",
    "-H", `Authorization: Basic ${auth}`,
    "-w", "\n__HTTP_STATUS__%{http_code}",
  ];
  if (body && (method === "POST" || method === "PUT" || method === "PATCH")) {
    args.push("-d", body);
  }
  args.push(url);

  const result = exec("curl", args, { timeout: 15_000 });
  const output = result.stdout;
  const statusMatch = output.match(/__HTTP_STATUS__(\d+)$/);
  const httpStatus = statusMatch ? parseInt(statusMatch[1], 10) : 0;
  const raw = output.replace(/__HTTP_STATUS__\d+$/, "").trim();

  if (!result.ok && httpStatus === 0) {
    return JSON.stringify({ error: result.stderr || "curl failed", status: 0 }, null, 2);
  }

  let data: unknown = raw;
  try { data = JSON.parse(raw); } catch { /* keep as string */ }
  const ok = httpStatus >= 200 && httpStatus < 400;
  return JSON.stringify(ok ? data : { error: `HTTP ${httpStatus}`, status: httpStatus, data }, null, 2);
}

export function registerStalwartTools(server: McpServer) {
  server.tool(
    "stalwart-users",
    "List all Stalwart mail accounts (principals)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: stalwartApi("GET", "/principal?limit=100") }],
    })
  );

  server.tool(
    "stalwart-user_detail",
    "Get details for a specific Stalwart user account",
    { name: z.string().describe("Account name (e.g. me@diegonmarcos.com)") },
    async ({ name }) => ({
      content: [{ type: "text" as const, text: stalwartApi("GET", `/principal/${encodeURIComponent(name)}`) }],
    })
  );

  server.tool(
    "stalwart-queue",
    "List messages in the Stalwart mail queue",
    {},
    async () => ({
      content: [{ type: "text" as const, text: stalwartApi("GET", "/queue/messages") }],
    })
  );

  server.tool(
    "stalwart-config",
    "Read Stalwart configuration settings (prefix filter)",
    { prefix: z.string().optional().describe("Config key prefix to filter (e.g. 'server.security', 'storage')") },
    async ({ prefix }) => {
      const path = prefix ? `/settings/list/${encodeURIComponent(prefix)}` : "/settings/list/server";
      return { content: [{ type: "text" as const, text: stalwartApi("GET", path) }] };
    }
  );

  server.tool(
    "stalwart-metrics",
    "Get Stalwart server telemetry metrics (connections, messages, errors)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: stalwartApi("GET", "/telemetry/metrics") }],
    })
  );

  server.tool(
    "stalwart-queue_action",
    "Perform action on queued messages (retry, cancel)",
    {
      action: z.enum(["retry", "cancel"]).describe("Action to perform"),
      id: z.string().describe("Message queue ID"),
    },
    async ({ action, id }) => ({
      content: [{ type: "text" as const, text: stalwartApi("PATCH", `/queue/messages/${encodeURIComponent(id)}`, JSON.stringify({ action })) }],
    })
  );

  server.tool(
    "stalwart-config_update",
    "Update a Stalwart configuration key",
    {
      key: z.string().describe("Config key (e.g. 'server.security.allowed-ip-addresses')"),
      value: z.string().describe("New value to set"),
    },
    async ({ key, value }) => ({
      content: [{ type: "text" as const, text: stalwartApi("PUT", `/settings/${encodeURIComponent(key)}`, JSON.stringify(value)) }],
    })
  );
}
