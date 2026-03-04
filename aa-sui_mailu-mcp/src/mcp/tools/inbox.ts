import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { withImap } from "../shared/imap.js";
import { simpleParser } from "mailparser";

export function registerInboxTools(server: McpServer): void {
  // ── mail_list_folders ──────────────────────────────────────────
  server.tool(
    "mail_list_folders",
    "List all IMAP folders with message counts",
    {},
    async () => {
      const result = await withImap(async (client) => {
        const folders: string[] = [];
        for await (const folder of client.list()) {
          folders.push(folder.path);
        }
        const details: string[] = [];
        for (const path of folders) {
          try {
            const status = await client.status(path, { messages: true, unseen: true });
            details.push(`${path}: ${status.messages ?? 0} messages, ${status.unseen ?? 0} unseen`);
          } catch {
            details.push(`${path}: (status unavailable)`);
          }
        }
        return details.join("\n");
      });
      return { content: [{ type: "text", text: result || "(no folders)" }] };
    }
  );

  // ── mail_list_messages ─────────────────────────────────────────
  server.tool(
    "mail_list_messages",
    "List messages in a folder (subject, from, date, flags, uid)",
    {
      folder: z.string().default("INBOX").describe("IMAP folder name"),
      limit: z.number().min(1).max(100).default(20).describe("Number of messages to return"),
      page: z.number().min(1).default(1).describe("Page number (1-based)"),
    },
    async ({ folder, limit, page }) => {
      const result = await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const status = await client.status(folder, { messages: true });
          const total = status.messages ?? 0;
          if (total === 0) return "(no messages)";

          const offset = (page - 1) * limit;
          const start = Math.max(1, total - offset - limit + 1);
          const end = Math.max(1, total - offset);

          const lines: string[] = [`Folder: ${folder} (${total} total, page ${page})\n`];
          for await (const msg of client.fetch(`${start}:${end}`, {
            uid: true,
            flags: true,
            envelope: true,
          })) {
            const env = msg.envelope;
            const from = env?.from?.[0]
              ? `${env.from[0].name || ""} <${env.from[0].address}>`.trim()
              : "(unknown)";
            const date = env?.date ? new Date(env.date).toISOString().slice(0, 16) : "?";
            const flags = msg.flags ? [...msg.flags].join(",") : "";
            const seen = flags.includes("\\Seen") ? " " : "●";
            lines.push(`${seen} UID:${msg.uid} [${date}] From: ${from}`);
            lines.push(`  Subject: ${env?.subject ?? "(no subject)"}`);
            if (flags) lines.push(`  Flags: ${flags}`);
          }
          return lines.join("\n");
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: result }] };
    }
  );

  // ── mail_read ──────────────────────────────────────────────────
  server.tool(
    "mail_read",
    "Read a full message (body text/html, headers, attachment list)",
    {
      folder: z.string().default("INBOX").describe("IMAP folder name"),
      uid: z.number().describe("Message UID"),
    },
    async ({ folder, uid }) => {
      const result = await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const msg = await client.fetchOne(`${uid}`, { source: true }, { uid: true });
          if (!msg) return `Message UID ${uid} not found in ${folder}`;

          const parsed = await simpleParser(msg.source);
          const lines: string[] = [];
          lines.push(`From: ${parsed.from?.text ?? "(unknown)"}`);
          lines.push(`To: ${parsed.to?.text ?? "(unknown)"}`);
          if (parsed.cc) lines.push(`Cc: ${parsed.cc.text}`);
          lines.push(`Date: ${parsed.date?.toISOString() ?? "?"}`);
          lines.push(`Subject: ${parsed.subject ?? "(no subject)"}`);
          lines.push(`Message-ID: ${parsed.messageId ?? ""}`);
          lines.push("");

          if (parsed.text) {
            lines.push("=== Body (text) ===");
            lines.push(parsed.text.slice(0, 8000));
          } else if (parsed.html) {
            lines.push("=== Body (HTML — text unavailable) ===");
            // Strip HTML tags for readability
            lines.push(parsed.html.replace(/<[^>]+>/g, "").slice(0, 8000));
          }

          if (parsed.attachments?.length) {
            lines.push("");
            lines.push("=== Attachments ===");
            parsed.attachments.forEach((att, i) => {
              lines.push(`  [${i}] ${att.filename ?? "unnamed"} (${att.contentType}, ${att.size ?? 0} bytes, part: ${att.partId ?? i})`);
            });
          }

          return lines.join("\n");
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: result }] };
    }
  );

  // ── mail_search ────────────────────────────────────────────────
  server.tool(
    "mail_search",
    "Search messages by criteria (from, subject, date, unseen)",
    {
      folder: z.string().default("INBOX").describe("IMAP folder name"),
      from: z.string().optional().describe("Filter by sender address"),
      subject: z.string().optional().describe("Filter by subject substring"),
      since: z.string().optional().describe("Filter messages since date (YYYY-MM-DD)"),
      unseen: z.boolean().optional().describe("Only unseen messages"),
      limit: z.number().min(1).max(50).default(20).describe("Max results"),
    },
    async ({ folder, from, subject, since, unseen, limit }) => {
      const result = await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const criteria: Record<string, unknown> = {};
          if (from) criteria.from = from;
          if (subject) criteria.subject = subject;
          if (since) criteria.since = new Date(since);
          if (unseen) criteria.seen = false;

          const uids = await client.search(criteria, { uid: true });
          if (!uids?.length) return "(no matches)";

          const topUids = uids.slice(-limit);
          const lines: string[] = [`Found ${uids.length} messages (showing last ${topUids.length}):\n`];

          for await (const msg of client.fetch(topUids.join(","), {
            uid: true,
            flags: true,
            envelope: true,
          }, { uid: true })) {
            const env = msg.envelope;
            const from_ = env?.from?.[0]
              ? `${env.from[0].name || ""} <${env.from[0].address}>`.trim()
              : "(unknown)";
            const date = env?.date ? new Date(env.date).toISOString().slice(0, 16) : "?";
            const seen = msg.flags?.has("\\Seen") ? " " : "●";
            lines.push(`${seen} UID:${msg.uid} [${date}] ${from_}`);
            lines.push(`  Subject: ${env?.subject ?? "(no subject)"}`);
          }
          return lines.join("\n");
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: result }] };
    }
  );

  // ── mail_flag ──────────────────────────────────────────────────
  server.tool(
    "mail_flag",
    "Set or unset a flag on a message (Seen, Flagged, Answered)",
    {
      folder: z.string().default("INBOX").describe("IMAP folder name"),
      uid: z.number().describe("Message UID"),
      flag: z.enum(["Seen", "Flagged", "Answered", "Deleted"]).describe("Flag name"),
      set: z.boolean().default(true).describe("true to add, false to remove"),
    },
    async ({ folder, uid, flag, set }) => {
      await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const imapFlag = `\\${flag}`;
          if (set) {
            await client.messageFlagsAdd(`${uid}`, [imapFlag], { uid: true });
          } else {
            await client.messageFlagsRemove(`${uid}`, [imapFlag], { uid: true });
          }
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: `Flag \\${flag} ${set ? "set" : "unset"} on UID ${uid} in ${folder}` }] };
    }
  );

  // ── mail_move ──────────────────────────────────────────────────
  server.tool(
    "mail_move",
    "Move a message to another folder",
    {
      folder: z.string().default("INBOX").describe("Source folder"),
      uid: z.number().describe("Message UID"),
      destination: z.string().describe("Destination folder name"),
    },
    async ({ folder, uid, destination }) => {
      await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          await client.messageMove(`${uid}`, destination, { uid: true });
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: `Moved UID ${uid} from ${folder} to ${destination}` }] };
    }
  );

  // ── mail_delete ────────────────────────────────────────────────
  server.tool(
    "mail_delete",
    "Delete a message (moves to Trash folder)",
    {
      folder: z.string().default("INBOX").describe("Source folder"),
      uid: z.number().describe("Message UID"),
    },
    async ({ folder, uid }) => {
      await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          await client.messageMove(`${uid}`, "Trash", { uid: true });
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: `Moved UID ${uid} to Trash` }] };
    }
  );

  // ── mail_download_attachment ───────────────────────────────────
  server.tool(
    "mail_download_attachment",
    "Get attachment content as base64",
    {
      folder: z.string().default("INBOX").describe("IMAP folder name"),
      uid: z.number().describe("Message UID"),
      filename: z.string().describe("Attachment filename to download"),
    },
    async ({ folder, uid, filename }) => {
      const result = await withImap(async (client) => {
        const lock = await client.getMailboxLock(folder);
        try {
          const msg = await client.fetchOne(`${uid}`, { source: true }, { uid: true });
          if (!msg) return `Message UID ${uid} not found`;

          const parsed = await simpleParser(msg.source);
          const att = parsed.attachments?.find(
            (a) => a.filename === filename
          );
          if (!att) {
            const names = parsed.attachments?.map((a) => a.filename).join(", ") ?? "none";
            return `Attachment "${filename}" not found. Available: ${names}`;
          }

          return `Filename: ${att.filename}\nContent-Type: ${att.contentType}\nSize: ${att.size} bytes\n\nBase64:\n${att.content.toString("base64")}`;
        } finally {
          lock.release();
        }
      });
      return { content: [{ type: "text", text: result }] };
    }
  );

  // ── mail_create_folder ─────────────────────────────────────────
  server.tool(
    "mail_create_folder",
    "Create a new IMAP folder",
    {
      name: z.string().describe("Folder name to create"),
    },
    async ({ name }) => {
      await withImap(async (client) => {
        await client.mailboxCreate(name);
      });
      return { content: [{ type: "text", text: `Folder "${name}" created` }] };
    }
  );

  // ── mail_delete_folder ─────────────────────────────────────────
  server.tool(
    "mail_delete_folder",
    "Delete an IMAP folder",
    {
      name: z.string().describe("Folder name to delete"),
    },
    async ({ name }) => {
      await withImap(async (client) => {
        await client.mailboxDelete(name);
      });
      return { content: [{ type: "text", text: `Folder "${name}" deleted` }] };
    }
  );
}
