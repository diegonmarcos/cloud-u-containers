import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { getTransport } from "../shared/smtp.js";
import { accountSchema } from "../shared/config.js";

export function registerSendTools(server: McpServer): void {
  server.tool(
    "gmail_send",
    "Send an email via Gmail SMTP using the account's App Password.",
    {
      account: accountSchema,
      to: z.union([z.string(), z.array(z.string())]),
      subject: z.string(),
      text: z.string().optional(),
      html: z.string().optional(),
      cc: z.union([z.string(), z.array(z.string())]).optional(),
      bcc: z.union([z.string(), z.array(z.string())]).optional(),
      reply_to: z.string().optional(),
      in_reply_to: z.string().optional(),
      references: z.union([z.string(), z.array(z.string())]).optional(),
    },
    async ({ account, to, subject, text, html, cc, bcc, reply_to, in_reply_to, references }) => {
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
          type: "text",
          text: JSON.stringify({ account: from, messageId: info.messageId, accepted: info.accepted, rejected: info.rejected, response: info.response }, null, 2),
        }],
      };
    },
  );
}
