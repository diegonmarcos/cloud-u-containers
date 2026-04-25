import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { listAccounts, configuredAccountAliases, getDefaultAccount } from "../shared/config.js";
import { withImap } from "../shared/imap.js";

export function registerAccountTools(server: McpServer): void {
  server.tool(
    "account_list",
    "List configured personal Google accounts (from build.json) and which have credentials present in env.",
    {},
    async () => {
      const all = listAccounts();
      const ready = new Set(configuredAccountAliases());
      const out = all.map((a) => ({
        alias: a.alias,
        email: a.email,
        default: a.default ?? false,
        credentials_loaded: ready.has(a.alias),
      }));
      const defaultAlias = (() => { try { return getDefaultAccount(); } catch { return null; } })();
      return { content: [{ type: "text", text: JSON.stringify({ default: defaultAlias, accounts: out }, null, 2) }] };
    },
  );

  server.tool(
    "account_test",
    "Verify IMAP login + INBOX selection for one or all configured accounts.",
    {},
    async () => {
      const aliases = configuredAccountAliases();
      const results: any[] = [];
      for (const alias of aliases) {
        try {
          const r = await withImap(alias, async (c, email) => {
            const lock = await c.getMailboxLock("INBOX");
            try {
              const status = await c.status("INBOX", { messages: true, unseen: true } as any);
              return { alias, email, ok: true, inbox: status };
            } finally { lock.release(); }
          });
          results.push(r);
        } catch (e: any) {
          results.push({ alias, ok: false, error: e?.message ?? String(e) });
        }
      }
      return { content: [{ type: "text", text: JSON.stringify({ tested: results.length, results }, null, 2) }] };
    },
  );
}
