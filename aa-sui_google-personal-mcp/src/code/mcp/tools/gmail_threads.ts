import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { withImap } from "../shared/imap.js";
import { accountSchema } from "../shared/config.js";

export function registerThreadTools(server: McpServer): void {
  server.tool(
    "gmail_thread_messages",
    "Fetch all messages in a Gmail conversation by X-GM-THRID (thread ID). Searches across [Gmail]/All Mail.",
    {
      account: accountSchema,
      thread_id: z.string().describe("Gmail thread ID (X-GM-THRID), as decimal string"),
      mailbox: z.string().default("[Gmail]/All Mail"),
    },
    async ({ account, thread_id, mailbox }) => {
      return await withImap(account, async (client, email) => {
        const lock = await client.getMailboxLock(mailbox);
        try {
          const uids = await client.search({ gmthrid: thread_id } as any, { uid: true });
          const sliced = (uids ?? []).slice(0, 200);
          const messages: any[] = [];
          for await (const msg of client.fetch(sliced, {
            uid: true,
            envelope: true,
            internalDate: true,
            flags: true,
            // @ts-expect-error
            "x-gm-msgid": true,
            // @ts-expect-error
            "x-gm-labels": true,
          } as any)) {
            messages.push({
              uid: msg.uid,
              subject: msg.envelope?.subject,
              from: msg.envelope?.from?.[0]?.address,
              date: msg.envelope?.date,
              flags: Array.from(msg.flags ?? []),
              gmMessageId: (msg as any)["x-gm-msgid"],
              gmLabels: (msg as any)["x-gm-labels"],
            });
          }
          return { content: [{ type: "text", text: JSON.stringify({ account: email, threadId: thread_id, count: messages.length, messages }, null, 2) }] };
        } finally {
          lock.release();
        }
      });
    },
  );
}
