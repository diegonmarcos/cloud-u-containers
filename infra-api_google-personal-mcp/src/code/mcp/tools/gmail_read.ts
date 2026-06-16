import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { simpleParser } from "mailparser";
import { withImap } from "../shared/imap.js";
import { accountSchema } from "../shared/config.js";

export function registerReadTools(server: McpServer): void {
  server.tool(
    "gmail_read",
    "Fetch and parse a single Gmail message by UID. Returns headers, plain text, and attachment metadata.",
    {
      account: accountSchema,
      uid: z.number().int().positive(),
      mailbox: z.string().default("INBOX"),
      include_html: z.boolean().default(false),
    },
    async ({ account, uid, mailbox, include_html }) => {
      return await withImap(account, async (client, email) => {
        const lock = await client.getMailboxLock(mailbox);
        try {
          const msg = await client.fetchOne(String(uid), { source: true, uid: true, flags: true } as any, { uid: true });
          if (!msg || !msg.source) throw new Error(`Message UID ${uid} not found in ${mailbox}`);
          const parsed = await simpleParser(msg.source as Buffer);
          const out = {
            account: email,
            uid: msg.uid,
            mailbox,
            flags: Array.from(msg.flags ?? []),
            subject: parsed.subject,
            from: parsed.from?.text,
            to: parsed.to ? (Array.isArray(parsed.to) ? parsed.to.map((x) => x.text) : parsed.to.text) : undefined,
            cc: parsed.cc ? (Array.isArray(parsed.cc) ? parsed.cc.map((x) => x.text) : parsed.cc.text) : undefined,
            date: parsed.date,
            messageId: parsed.messageId,
            inReplyTo: parsed.inReplyTo,
            text: parsed.text,
            html: include_html ? parsed.html : undefined,
            attachments: (parsed.attachments ?? []).map((a) => ({
              filename: a.filename,
              contentType: a.contentType,
              size: a.size,
            })),
          };
          return { content: [{ type: "text", text: JSON.stringify(out, null, 2) }] };
        } finally {
          lock.release();
        }
      });
    },
  );
}
