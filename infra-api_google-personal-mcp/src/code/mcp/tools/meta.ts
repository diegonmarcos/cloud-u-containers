/**
 * Meta-tool — single entry point dispatching to all 9 Google personal handlers.
 * Replaces individual tool registrations with one `google_personal` tool.
 *
 * Methods:
 *   account_list          — list configured accounts from build.json
 *   account_test          — verify IMAP login for all configured accounts
 *   gmail_search          — search Gmail via IMAP X-GM-RAW
 *   gmail_read            — fetch + parse a single message by UID
 *   gmail_send            — send email via Gmail SMTP
 *   gmail_labels_list     — list all Gmail labels / mailboxes
 *   gmail_label_apply     — add or remove labels on a message
 *   gmail_message_move    — move a message between mailboxes
 *   gmail_thread_messages — fetch all messages in a thread by X-GM-THRID
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { simpleParser } from "mailparser";
import {
  listAccounts,
  configuredAccountAliases,
  getDefaultAccount,
  accountSchema,
} from "../shared/config.js";
import { withImap } from "../shared/imap.js";
import { getTransport } from "../shared/smtp.js";

// ── method enum ───────────────────────────────────────────────────────────────

const METHODS = [
  "account_list",
  "account_test",
  "gmail_search",
  "gmail_read",
  "gmail_send",
  "gmail_labels_list",
  "gmail_label_apply",
  "gmail_message_move",
  "gmail_thread_messages",
] as const;

type Method = typeof METHODS[number];

// ── handler result type ───────────────────────────────────────────────────────

type HandlerResult = { content: Array<{ type: "text"; text: string }> };

// ── handlers (all logic inlined) ──────────────────────────────────────────────

const handlers: Record<Method, (params: Record<string, unknown>) => Promise<HandlerResult>> = {

  account_list: async () => {
    const all = listAccounts();
    const ready = new Set(configuredAccountAliases());
    const out = all.map((a) => ({
      alias: a.alias,
      email: a.email,
      default: a.default ?? false,
      credentials_loaded: ready.has(a.alias),
    }));
    const defaultAlias = (() => { try { return getDefaultAccount(); } catch { return null; } })();
    return { content: [{ type: "text" as const, text: JSON.stringify({ default: defaultAlias, accounts: out }, null, 2) }] };
  },

  account_test: async () => {
    const aliases = configuredAccountAliases();
    const results: unknown[] = [];
    for (const alias of aliases) {
      try {
        const result = await withImap(alias, async (client, email) => {
          const lock = await client.getMailboxLock("INBOX");
          try {
            const status = await client.status("INBOX", { messages: true, unseen: true } as any);
            return { alias, email, ok: true, inbox: status };
          } finally {
            lock.release();
          }
        });
        results.push(result);
      } catch (error: any) {
        results.push({ alias, ok: false, error: error?.message ?? String(error) });
      }
    }
    return { content: [{ type: "text" as const, text: JSON.stringify({ tested: results.length, results }, null, 2) }] };
  },

  gmail_search: async (params) => {
    const account = params["account"] as string | undefined;
    const query = params["query"] as string;
    const mailbox = (params["mailbox"] as string | undefined) ?? "INBOX";
    const limit = (params["limit"] as number | undefined) ?? 25;
    return await withImap(account, async (client, email) => {
      const lock = await client.getMailboxLock(mailbox);
      try {
        // Gmail's X-GM-RAW lets us pass the full Gmail search syntax.
        const uids = await client.search({ gmraw: query } as any, { uid: true });
        const sliced = (uids ?? []).slice(-limit).reverse();
        const results: unknown[] = [];
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
            from: msg.envelope?.from?.map((address) => `${address.name ?? ""} <${address.address}>`),
            to: msg.envelope?.to?.map((address) => address.address),
            date: msg.envelope?.date,
            flags: Array.from(msg.flags ?? []),
            size: msg.size,
            gmThreadId: (msg as any)["x-gm-thrid"],
            gmMessageId: (msg as any)["x-gm-msgid"],
            gmLabels: (msg as any)["x-gm-labels"],
          });
        }
        return { content: [{ type: "text" as const, text: JSON.stringify({ account: email, mailbox, query, count: results.length, messages: results }, null, 2) }] };
      } finally {
        lock.release();
      }
    });
  },

  gmail_read: async (params) => {
    const account = params["account"] as string | undefined;
    const uid = params["uid"] as number;
    const mailbox = (params["mailbox"] as string | undefined) ?? "INBOX";
    const include_html = (params["include_html"] as boolean | undefined) ?? false;
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
          attachments: (parsed.attachments ?? []).map((attachment) => ({
            filename: attachment.filename,
            contentType: attachment.contentType,
            size: attachment.size,
          })),
        };
        return { content: [{ type: "text" as const, text: JSON.stringify(out, null, 2) }] };
      } finally {
        lock.release();
      }
    });
  },

  gmail_send: async (params) => {
    const account = params["account"] as string | undefined;
    const to = params["to"] as string | string[];
    const subject = params["subject"] as string;
    const text = params["text"] as string | undefined;
    const html = params["html"] as string | undefined;
    const cc = params["cc"] as string | string[] | undefined;
    const bcc = params["bcc"] as string | string[] | undefined;
    const reply_to = params["reply_to"] as string | undefined;
    const in_reply_to = params["in_reply_to"] as string | undefined;
    const references = params["references"] as string | string[] | undefined;
    if (!text && !html) throw new Error("Either 'text' or 'html' must be provided");
    const { transport, from } = getTransport(account);
    const info = await transport.sendMail({
      from,
      to,
      subject,
      text,
      html,
      cc,
      bcc,
      replyTo: reply_to,
      inReplyTo: in_reply_to,
      references,
    });
    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify({ account: from, messageId: info.messageId, accepted: info.accepted, rejected: info.rejected, response: info.response }, null, 2),
      }],
    };
  },

  gmail_labels_list: async (params) => {
    const account = params["account"] as string | undefined;
    return await withImap(account, async (client, email) => {
      const list = await client.list();
      const out = list.map((mailbox) => ({ path: mailbox.path, flags: Array.from(mailbox.flags ?? []), specialUse: mailbox.specialUse }));
      return { content: [{ type: "text" as const, text: JSON.stringify({ account: email, count: out.length, mailboxes: out }, null, 2) }] };
    });
  },

  gmail_label_apply: async (params) => {
    const account = params["account"] as string | undefined;
    const uid = params["uid"] as number;
    const mailbox = (params["mailbox"] as string | undefined) ?? "INBOX";
    const add = params["add"] as string[] | undefined;
    const remove = params["remove"] as string[] | undefined;
    return await withImap(account, async (client, email) => {
      const lock = await client.getMailboxLock(mailbox);
      try {
        const ops: any = {};
        if (add?.length) ops["+x-gm-labels"] = add;
        if (remove?.length) ops["-x-gm-labels"] = remove;
        if (Object.keys(ops).length === 0) throw new Error("Provide 'add' or 'remove'");
        await client.messageFlagsAdd(String(uid), [], { uid: true, ...ops });
        return { content: [{ type: "text" as const, text: JSON.stringify({ account: email, uid, applied: ops }, null, 2) }] };
      } finally {
        lock.release();
      }
    });
  },

  gmail_message_move: async (params) => {
    const account = params["account"] as string | undefined;
    const uid = params["uid"] as number;
    const from = (params["from"] as string | undefined) ?? "INBOX";
    const to = params["to"] as string;
    return await withImap(account, async (client, email) => {
      const lock = await client.getMailboxLock(from);
      try {
        const result = await client.messageMove(String(uid), to, { uid: true });
        return { content: [{ type: "text" as const, text: JSON.stringify({ account: email, uid, from, to, result }, null, 2) }] };
      } finally {
        lock.release();
      }
    });
  },

  gmail_thread_messages: async (params) => {
    const account = params["account"] as string | undefined;
    const thread_id = params["thread_id"] as string;
    const mailbox = (params["mailbox"] as string | undefined) ?? "[Gmail]/All Mail";
    return await withImap(account, async (client, email) => {
      const lock = await client.getMailboxLock(mailbox);
      try {
        const uids = await client.search({ gmthrid: thread_id } as any, { uid: true });
        const sliced = (uids ?? []).slice(0, 200);
        const messages: unknown[] = [];
        // imapflow API: options.uid=true must be the THIRD arg, not in
        // the fetch-query object. Mixing it in makes imapflow treat
        // `sliced` as sequence numbers — silently returns nothing for
        // UIDs > current message count. See gmail_search handler for
        // the root-cause analysis (same bug, same fix).
        for await (const msg of client.fetch(sliced, {
          envelope: true,
          internalDate: true,
          flags: true,
          // @ts-expect-error gmail extensions
          "x-gm-msgid": true,
          // @ts-expect-error gmail extensions
          "x-gm-labels": true,
        } as any, { uid: true })) {
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
        return { content: [{ type: "text" as const, text: JSON.stringify({ account: email, threadId: thread_id, count: messages.length, messages }, null, 2) }] };
      } finally {
        lock.release();
      }
    });
  },
};

// ── params schema (superset of all method params) ─────────────────────────────

const paramsSchema = z.object({
  account: accountSchema,
  query: z.string().optional().describe("gmail_search: Gmail search query (e.g. 'from:foo@bar.com is:unread')"),
  mailbox: z.string().optional().describe("gmail_search/gmail_read/gmail_label_apply/gmail_thread_messages: mailbox name (default: INBOX; use '[Gmail]/All Mail' for thread search)"),
  limit: z.number().int().positive().max(200).optional().describe("gmail_search: max results (default 25, max 200)"),
  uid: z.number().int().positive().optional().describe("gmail_read/gmail_label_apply/gmail_message_move: message UID"),
  include_html: z.boolean().optional().describe("gmail_read: include HTML body (default false)"),
  to: z.union([z.string(), z.array(z.string())]).optional().describe("gmail_send: recipient(s)"),
  subject: z.string().optional().describe("gmail_send: subject"),
  text: z.string().optional().describe("gmail_send: plain text body"),
  html: z.string().optional().describe("gmail_send: HTML body"),
  cc: z.union([z.string(), z.array(z.string())]).optional().describe("gmail_send: CC"),
  bcc: z.union([z.string(), z.array(z.string())]).optional().describe("gmail_send: BCC"),
  reply_to: z.string().optional().describe("gmail_send: Reply-To address"),
  in_reply_to: z.string().optional().describe("gmail_send: In-Reply-To header"),
  references: z.union([z.string(), z.array(z.string())]).optional().describe("gmail_send: References header"),
  add: z.array(z.string()).optional().describe("gmail_label_apply: labels to add"),
  remove: z.array(z.string()).optional().describe("gmail_label_apply: labels to remove"),
  from: z.string().optional().describe("gmail_message_move: source mailbox (default: INBOX)"),
  thread_id: z.string().optional().describe("gmail_thread_messages: Gmail thread ID (X-GM-THRID) as decimal string"),
});

// ── registration ──────────────────────────────────────────────────────────────

export function registerMetaTool(server: McpServer): void {
  server.tool(
    "google_personal",
    [
      "Unified access to personal Google/Gmail accounts via IMAP/SMTP.",
      "Pass `method` to select the operation; include any required params in the same object.",
      "",
      "Methods:",
      "  account_list          — list configured accounts from build.json and credential status",
      "  account_test          — verify IMAP login + INBOX selection for all configured accounts",
      "  gmail_search          — search Gmail using IMAP X-GM-RAW (supports full Gmail query syntax)",
      "  gmail_read            — fetch and parse a single message by UID (headers, text, attachments)",
      "  gmail_send            — send email via Gmail SMTP using an account's App Password",
      "  gmail_labels_list     — list all Gmail labels mapped to IMAP mailboxes",
      "  gmail_label_apply     — add or remove Gmail labels on a message (X-GM-LABELS)",
      "  gmail_message_move    — move a message between mailboxes via IMAP MOVE",
      "  gmail_thread_messages — fetch all messages in a conversation by X-GM-THRID thread ID",
    ].join("\n"),
    {
      method: z.enum(METHODS).describe("Operation to perform"),
      ...paramsSchema.shape,
    },
    async ({ method, ...params }) => {
      const handler = handlers[method];
      return handler(params as Record<string, unknown>);
    },
  );
}
