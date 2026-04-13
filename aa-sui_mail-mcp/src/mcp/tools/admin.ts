import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { listAccounts, listDomains } from "../shared/admin.js";

export function registerAdminTools(server: McpServer): void {
  server.tool(
    "mail_admin_users",
    "Manage Maddy mailbox users (list/create/delete)",
    {
      action: z.enum(["list"]).describe("Action to perform (list only — use SSH for create/delete)"),
    },
    async () => {
      const accounts = await listAccounts();
      const output = accounts.length ? accounts.join("\n") : "(no accounts)";
      return { content: [{ type: "text", text: output }] };
    }
  );

  server.tool(
    "mail_admin_domains",
    "List Maddy mail domains",
    {},
    async () => {
      const domains = await listDomains();
      return { content: [{ type: "text", text: domains.length ? domains.join("\n") : "(no domains)" }] };
    }
  );
}
