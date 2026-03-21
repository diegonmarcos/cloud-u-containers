import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { listAccounts, createAccount, deleteAccount, listDomains } from "../shared/admin.js";

export function registerAdminTools(server: McpServer): void {
  server.tool(
    "mail_admin_users",
    "Manage Stalwart mailbox users (list/create/delete)",
    {
      action: z.enum(["list", "create", "delete"]).describe("Action to perform"),
      user: z.string().optional().describe("User email (required for create/delete)"),
      password: z.string().optional().describe("Password (required for create)"),
    },
    async ({ action, user, password }) => {
      let output: string;

      if (action === "list") {
        const accounts = await listAccounts();
        output = accounts.length ? accounts.join("\n") : "(no accounts)";
      } else if (action === "create") {
        if (!user || !password) throw new Error("user and password required for create");
        await createAccount(user, password);
        output = `Created: ${user}`;
      } else {
        if (!user) throw new Error("user required for delete");
        await deleteAccount(user);
        output = `Deleted: ${user}`;
      }

      return { content: [{ type: "text", text: output }] };
    }
  );

  server.tool(
    "mail_admin_domains",
    "List Stalwart mail domains",
    {},
    async () => {
      const domains = await listDomains();
      return { content: [{ type: "text", text: domains.length ? domains.join("\n") : "(no domains)" }] };
    }
  );
}
