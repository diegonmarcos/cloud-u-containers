import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { flaskMailu } from "../shared/admin.js";

export function registerAdminTools(server: McpServer): void {
  // ── mail_admin_users ───────────────────────────────────────────
  server.tool(
    "mail_admin_users",
    "Manage Mailu mailbox users (list/create/delete)",
    {
      action: z.enum(["list", "create", "delete"]).describe("Action to perform"),
      user: z.string().optional().describe("User email (required for create/delete)"),
      password: z.string().optional().describe("Password (required for create)"),
    },
    async ({ action, user, password }) => {
      let output: string;

      if (action === "list") {
        // config-export shows all users/domains (no dedicated user-list command)
        output = flaskMailu("config-export -j user");
      } else if (action === "create") {
        if (!user || !password) throw new Error("user and password required for create");
        const [localPart, domain] = user.split("@");
        output = flaskMailu(`user ${localPart} ${domain} ${password}`);
      } else {
        if (!user) throw new Error("user required for delete");
        // user-delete takes full email + -r flag to actually delete (without -r just disables)
        output = flaskMailu(`user-delete -r ${user}`);
      }

      return { content: [{ type: "text", text: output || "(done)" }] };
    }
  );

  // ── mail_admin_aliases ─────────────────────────────────────────
  server.tool(
    "mail_admin_aliases",
    "Manage Mailu email aliases (list/create/delete)",
    {
      action: z.enum(["list", "create", "delete"]).describe("Action to perform"),
      alias: z.string().optional().describe("Alias email address (required for create/delete)"),
      destination: z.string().optional().describe("Destination address (required for create)"),
    },
    async ({ action, alias, destination }) => {
      let output: string;

      if (action === "list") {
        output = flaskMailu("alias-list");
      } else if (action === "create") {
        if (!alias || !destination) throw new Error("alias and destination required for create");
        const [localPart, domain] = alias.split("@");
        output = flaskMailu(`alias-create ${localPart} ${domain} ${destination}`);
      } else {
        if (!alias) throw new Error("alias required for delete");
        const [localPart, domain] = alias.split("@");
        output = flaskMailu(`alias-delete ${localPart} ${domain}`);
      }

      return { content: [{ type: "text", text: output || "(done)" }] };
    }
  );
}
