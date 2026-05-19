import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { withImap } from "../shared/imap.js";
import { accountSchema } from "../shared/config.js";

export function registerSearchTools(server: McpServer): void {
  server.tool(
    "gmail_search",
    "Search Gmail using IMAP SEARCH. Supports common Gmail extensions via X-GM-RAW (Gmail-style query language: from:, to:, subject:, has:attachment, is:unread, label:, after:YYYY/MM/DD, before:YYYY/MM/DD).",
    {
      account: accountSchema,
      query: z.string().describe("Gmail search query (e.g. 'from:foo@bar.com is:unread')"),
      mailbox: z.string().default("INBOX").describe("Mailbox to search (default: INBOX). Use 'All Mail' aliased '[Gmail]/All Mail'."),
      limit: z.number().int().positive().max(200).default(25),
    },
    async ({ account, query, mailbox, limit }) => {
      return await withImap(account, async (client, email) => {
        const lock = await client.getMailboxLock(mailbox);
        try {
          // Gmail's X-GM-RAW lets us pass the full Gmail search syntax.
          const uids = await client.search({ gmraw: query } as any, { uid: true });
          const sliced = (uids ?? []).slice(-limit).reverse();
          const results: any[] = [];
          // imapflow API: fetch(range, query, options). `options.uid:true`
          // MUST be the THIRD arg — placing it in the query object makes
          // imapflow treat the range as SEQUENCE numbers, which silently
          // returns nothing whenever a UID > current message count.
          for await (const msg of client.fetch(sliced, {
            envelope: true,
            flags: true,
            internalDate: true,
            size: true,
            // @ts-expect-error gmail extensions
            "x-gm-thrid": true,
            // @ts-expect-error gmail extensions
            "x-gm-msgid": true,
            // @ts-expect-error gmail extensions
            "x-gm-labels": true,
          } as any, { uid: true })) {
            results.push({
              uid: msg.uid,
              subject: msg.envelope?.subject,
              from: msg.envelope?.from?.map((a) => `${a.name ?? ""} <${a.address}>`),
              to: msg.envelope?.to?.map((a) => a.address),
              date: msg.envelope?.date,
              flags: Array.from(msg.flags ?? []),
              size: msg.size,
              gmThreadId: (msg as any)["x-gm-thrid"],
              gmMessageId: (msg as any)["x-gm-msgid"],
              gmLabels: (msg as any)["x-gm-labels"],
            });
          }
          return {
            content: [{ type: "text", text: JSON.stringify({ account: email, mailbox, query, count: results.length, messages: results }, null, 2) }],
          };
        } finally {
          lock.release();
        }
      });
    },
  );
}
