import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { stalwartAdminFetch } from "../shared/admin.js";

export async function handle_stalwart_admin_accounts({ name }: { name: any }) {
  if (name) {
    const data = await stalwartAdminFetch(`/api/principal/${encodeURIComponent(name)}`);
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }
  const data = await stalwartAdminFetch("/api/principal?type=individual&limit=100");
  const items = data?.data?.items ?? data?.items ?? [];
  if (!items.length) return { content: [{ type: "text", text: "(no accounts)" }] };
  const lines = items.map((p: any) => typeof p === "string" ? p : `${p.name} (${p.type ?? "?"})`);
  return { content: [{ type: "text", text: `${items.length} accounts:\n${lines.join("\n")}` }] };
}

export async function handle_stalwart_admin_domains(_params: Record<string, unknown>) {
  const data = await stalwartAdminFetch("/api/principal?type=domain&limit=100");
  const items = data?.data?.items ?? data?.items ?? [];
  if (!items.length) return { content: [{ type: "text", text: "(no domains)" }] };
  const lines = items.map((d: any) => typeof d === "string" ? d : d.name ?? JSON.stringify(d));
  return { content: [{ type: "text", text: `${items.length} domains:\n${lines.join("\n")}` }] };
}

export async function handle_stalwart_admin_settings({ prefix }: { prefix: any }) {
  const path = prefix
    ? `/api/settings/list?prefix=${encodeURIComponent(prefix)}`
    : "/api/settings/list";
  const data = await stalwartAdminFetch(path);
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

export function registerStalwartTools(server: McpServer): void {
  // ── stalwart_admin_accounts ──────────────────────────────────
  server.tool(
    "stalwart_admin_accounts",
    "List or inspect Stalwart accounts via admin API",
    {
      name: z.string().optional().describe("Account name to inspect (omit to list all)"),
    },
    handle_stalwart_admin_accounts
  );

  // ── stalwart_admin_domains ───────────────────────────────────
  server.tool(
    "stalwart_admin_domains",
    "List domains configured in Stalwart via admin API",
    {},
    handle_stalwart_admin_domains
  );

  // ── stalwart_admin_settings ──────────────────────────────────
  server.tool(
    "stalwart_admin_settings",
    "Get Stalwart server settings via admin API",
    {
      prefix: z.string().default("").describe("Settings prefix to filter (e.g. 'server.listener', 'store')"),
    },
    handle_stalwart_admin_settings
  );
}
