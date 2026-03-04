import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { getTransport } from "../shared/smtp.js";
import { withImap } from "../shared/imap.js";
import { simpleParser } from "mailparser";

export function registerComposeTools(server: McpServer): void {
  // ── mail_send ──────────────────────────────────────────────────
  server.tool(
    "mail_send",
    "Send a new email",
    {
      to: z.string().describe("Recipient address(es), comma-separated"),
      subject: z.string().describe("Email subject"),
      body: z.string().describe("Email body (plain text)"),
      cc: z.string().optional().describe("CC address(es), comma-separated"),
      bcc: z.string().optional().describe("BCC address(es), comma-separated"),
      html: z.string().optional().describe("HTML body (overrides plain text body for HTML part)"),
    },
    async ({ to, subject, body, cc, bcc, html }) => {
      const transport = getTransport();
      const info = await transport.sendMail({
        from: process.env.MAIL_USER,
        to,
        subject,
        text: body,
        html: html ?? undefined,
        cc: cc ?? undefined,
        bcc: bcc ?? undefined,
      });
      return { content: [{ type: "text", text: `Sent. Message-ID: ${info.messageId}` }] };
    }
  );

  // ── mail_reply ─────────────────────────────────────────────────
  server.tool(
    "mail_reply",
    "Reply to a message (quotes original, preserves thread headers)",
    {
      folder: z.string().default("INBOX").describe("Folder containing the original message"),
      uid: z.number().describe("UID of the message to reply to"),
      body: z.string().describe("Reply body text"),
      replyAll: z.boolean().default(false).describe("Reply to all recipients"),
    },
    async ({ folder, uid, body, replyAll }) => {
      const original = await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const msg = await client.fetchOne(`${uid}`, { source: true }, { uid: true });
          if (!msg) throw new Error(`Message UID ${uid} not found`);
          return await simpleParser(msg.source);
        } finally {
          lock.release();
        }
      });

      const replyTo = original.from?.text ?? "";
      const ccAddresses = replyAll
        ? [
            ...(original.to ? [original.to.text] : []),
            ...(original.cc ? [original.cc.text] : []),
          ]
            .join(", ")
        : undefined;

      const quotedBody = (original.text ?? "")
        .split("\n")
        .map((line) => `> ${line}`)
        .join("\n");

      const subject = original.subject?.startsWith("Re:") ? original.subject : `Re: ${original.subject ?? ""}`;

      const transport = getTransport();
      const info = await transport.sendMail({
        from: process.env.MAIL_USER,
        to: replyTo,
        cc: ccAddresses ?? undefined,
        subject,
        text: `${body}\n\n${quotedBody}`,
        references: original.references
          ? (Array.isArray(original.references) ? original.references.join(" ") : original.references)
          : original.messageId ?? undefined,
        inReplyTo: original.messageId ?? undefined,
      });
      return { content: [{ type: "text", text: `Reply sent to ${replyTo}. Message-ID: ${info.messageId}` }] };
    }
  );

  // ── mail_forward ───────────────────────────────────────────────
  server.tool(
    "mail_forward",
    "Forward a message with its attachments",
    {
      folder: z.string().default("INBOX").describe("Folder containing the original message"),
      uid: z.number().describe("UID of the message to forward"),
      to: z.string().describe("Forward recipient(s), comma-separated"),
      body: z.string().default("").describe("Optional message to prepend before forwarded content"),
    },
    async ({ folder, uid, to, body }) => {
      const original = await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const msg = await client.fetchOne(`${uid}`, { source: true }, { uid: true });
          if (!msg) throw new Error(`Message UID ${uid} not found`);
          return await simpleParser(msg.source);
        } finally {
          lock.release();
        }
      });

      const fwdHeader = [
        "---------- Forwarded message ----------",
        `From: ${original.from?.text ?? "?"}`,
        `Date: ${original.date?.toISOString() ?? "?"}`,
        `Subject: ${original.subject ?? "(no subject)"}`,
        `To: ${original.to?.text ?? "?"}`,
        "",
      ].join("\n");

      const subject = original.subject?.startsWith("Fwd:") ? original.subject : `Fwd: ${original.subject ?? ""}`;

      const attachments = original.attachments?.map((att) => ({
        filename: att.filename ?? "attachment",
        content: att.content,
        contentType: att.contentType,
      }));

      const transport = getTransport();
      const info = await transport.sendMail({
        from: process.env.MAIL_USER,
        to,
        subject,
        text: `${body}\n\n${fwdHeader}${original.text ?? ""}`,
        attachments: attachments ?? [],
      });
      return { content: [{ type: "text", text: `Forwarded to ${to}. Message-ID: ${info.messageId}` }] };
    }
  );
}
