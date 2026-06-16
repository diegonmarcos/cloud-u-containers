import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { withImap } from "../shared/imap.js";
import { accountSchema } from "../shared/config.js";

export function registerLabelTools(server: McpServer): void {
  server.tool(
    "gmail_labels_list",
    "List all Gmail labels (mapped to IMAP mailboxes) for the account.",
    { account: accountSchema },
    async ({ account }) => {
      return await withImap(account, async (client, email) => {
        const list = await client.list();
        const out = list.map((m) => ({ path: m.path, flags: Array.from(m.flags ?? []), specialUse: m.specialUse }));
        return { content: [{ type: "text", text: JSON.stringify({ account: email, count: out.length, mailboxes: out }, null, 2) }] };
      });
    },
  );

  server.tool(
    "gmail_label_apply",
    "Apply or remove Gmail labels on a message via IMAP X-GM-LABELS extension.",
    {
      account: accountSchema,
      uid: z.number().int().positive(),
      mailbox: z.string().default("INBOX"),
      add: z.array(z.string()).optional().describe("Labels to add (e.g. ['Important','Custom/Sub'])"),
      remove: z.array(z.string()).optional().describe("Labels to remove"),
    },
    async ({ account, uid, mailbox, add, remove }) => {
      return await withImap(account, async (client, email) => {
        const lock = await client.getMailboxLock(mailbox);
        try {
          const ops: any = {};
          if (add?.length) ops["+x-gm-labels"] = add;
          if (remove?.length) ops["-x-gm-labels"] = remove;
          if (Object.keys(ops).length === 0) throw new Error("Provide 'add' or 'remove'");
          await client.messageFlagsAdd(String(uid), [], { uid: true, ...ops });
          return { content: [{ type: "text", text: JSON.stringify({ account: email, uid, applied: ops }, null, 2) }] };
        } finally {
          lock.release();
        }
      });
    },
  );

  server.tool(
    "gmail_message_move",
    "Move a message between mailboxes/labels (IMAP MOVE).",
    {
      account: accountSchema,
      uid: z.number().int().positive(),
      from: z.string().default("INBOX"),
      to: z.string(),
    },
    async ({ account, uid, from, to }) => {
      return await withImap(account, async (client, email) => {
        const lock = await client.getMailboxLock(from);
        try {
          const result = await client.messageMove(String(uid), to, { uid: true });
          return { content: [{ type: "text", text: JSON.stringify({ account: email, uid, from, to, result }, null, 2) }] };
        } finally {
          lock.release();
        }
      });
    },
  );
}
